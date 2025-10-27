## ReFoRCE Snow 端到端运行流程说明（基于 scripts/run_main.sh）

本文面向任务 task=snow，逐步讲解 `scripts/run_main.sh` 在一次完整运行中的所有阶段、涉及到的 Python 脚本与关键实现逻辑、输入输出产物，以及常见问题提示与可调参数。文件/符号名均以本仓库为基准（路径相对 `methods/ReFoRCE`）。

---

## 总览

`scripts/run_main.sh --task snow --model <MODEL>` 主要串起以下阶段：

1) 准备样例与凭据：`spider_agent_setup_snow.py`
2) 压缩 schema 信息、构建 prompts：`reconstruct_data.py`
3) 表级 Schema Linking（可选列裁剪）并回写 DDL_sl：`schema_linking.py`
4) 生成与执行 SQL、投票与重跑（含列探索阶段）：`run.py`（两轮）+ `agent.py` + `sql.py` + `chat.py` + `prompt.py`
5) 中间与最终评估：`eval.py`
6) 结果打包：`get_metadata.py` + Spider2 官方评测：`spider2-snow/evaluation_suite/evaluate.py`

所有阶段的输出统一写到 `output/<MODEL>-snow-log-<TIMESTAMP>/` 目录下（每个样例一个子目录）。

---

## 1. 样例与凭据准备：spider_agent_setup_snow.py

- 脚本：`spider_agent_setup_snow.py`
- 入口参数（由 run_main.sh 传入）：
  - `--example_folder examples_snow`
- 主要动作：
  - 从 `../../spider2-snow/spider2-snow.jsonl` 读取样例（每行一个 JSON，含 `instance_id`、`db_id`、`external_knowledge` 等）。
  - 在 `examples_snow/<instance_id>/` 下为每个样例创建目录；若 `external_knowledge` 指向文档文件，则复制到样例目录。
  - 将仓库根下 `methods/ReFoRCE/snowflake_credential.json` 复制到每个样例目录下（用于 Snowflake 连接）。
  - 将 `../../spider2-snow/resource/databases/<db_id>/` 整个拷贝到样例目录下，形成每个样例的 DB 目录（包含 DDL.csv 和各表 JSON）。

输出物：
- `examples_snow/<instance_id>/`：内含 DB 目录、凭据、（可选）外部文档。

注意：
- `snowflake_credential.json` 需符合 Snowflake Python Connector 的参数：至少 `user`、`password`、`account`；可选 `warehouse`、`database`、`schema`、`role`、`session_parameters`。

---

## 2. Schema 压缩与 prompts 构建：reconstruct_data.py

- 脚本：`reconstruct_data.py`
- 入口参数（固定于 run_main.sh）：
  - `--example_folder examples_snow`
  - `--add_description`：将列的描述拼入 prompts
  - `--add_sample_rows`：将样例行拼入 prompts
  - `--rm_digits`：按“去数字后的前缀”聚类相似表，并以“代表表”对比 schema 一致性
  - `--make_folder`：规范化每个样例的 DB 目录与文件布局
  - `--clear_long_eg_des`：当 prompts 超阈值时清理冗长描述

核心逻辑：
- 遍历 `examples_snow/<instance_id>/<db_id>/` 下的 `DDL.csv` 与 `<table>.json`，将每张表的列名、类型、（可选）描述与样例行，汇总生成 `prompts.txt`。
- 当 `--rm_digits` 开启：
  - 将表名去数字后作为 key 聚类（如 `GA_SESSIONS_YYYYMMDD`），挑选“代表表”。
  - 使用 `utils.is_same_schema` 比对代表表与同组其他表的列集合是否一致；不一致则打印差异（不终止流程）。
  - 在 prompts 尾部额外附上“类似结构的表名列表”。

输出物：
- `examples_snow/<instance_id>/prompts.txt`：包含表结构、（可选）样例行、（可选）类似结构列表、（可选）外部文档摘要等。

---

## 3. 表级 Schema Linking 与列裁剪：schema_linking.py

- 脚本：`schema_linking.py`
- 入口参数（固定于 run_main.sh）：
  - `--task snow`
  - `--db_path examples_snow`
  - `--linked_json_pth ../../data/linked_snow_tmp0.json`
  - `--reduce_col`：允许基于 Linking 结果裁剪 DDL 的列

两步流程：
1) 读取 `linked_snow_tmp0.json`（若不存在且选择 `linking_method=naive` 时，会走生成流程 ask_model_sl，默认脚本中未触发），解析每个样例下与任务相关的表与列。
2) 将 `DDL.csv` 处理生成 `DDL_sl.csv`：
   - 若 prompts 过长（> 阈值）或 `--reduce_col` 开启，则筛选/裁剪到与任务最相关的表/列
   - 写入 DDL_sl.csv 后，调用 `compress_ddl(..., schema_linked=True, reduce_col=...)` 重新生成更短的 `prompts.txt`

输出物：
- `examples_snow/<instance_id>/<db_id>/DDL_sl.csv`（当有 Linking 结果时）
- 更新后的 `prompts.txt`（列更少、表更聚焦）

提示：
- 该阶段主要为后续 LLM 生成 SQL 降低上下文长度与干扰，提高召回关键表与列的概率。

---

## 4. 生成/执行/投票/重跑：run.py + agent.py + chat.py + prompt.py + sql.py

### 4.1 调度入口：run.py（两轮）

run_main.sh 先后执行两次 `run.py`：

- Step 1（多数投票 + 自我迭代）：
  - 关键参数：`--do_self_refinement --do_vote --num_votes 8 --num_workers 16`
  - 不包含列探索（`--do_column_exploration` 未开）

- Step 2（列探索 + 多数投票 + 自我迭代 + 重跑）：
  - 关键参数：`--do_column_exploration --rerun --overwrite_unfinished` 其余同 Step 1
  - 若某样例没有最终 `result.sql`，会先清空目录再重跑所有候选，使每个 `xlog.log` 都包含 `[Exploration]`

运行机制（共同点）：
- `get_dictionary(db_path, task)` 提供样例清单与任务文本。
- 每个样例建独立目录 `output/<MODEL>-snow-log-<TIME>/<instance_id>/`。
- 若 `--do_vote`：为该样例并发启动 `num_votes` 个候选线程，每个候选产出三件套：
  - `iresult.sql`、`iresult.csv`、`ilog.log`（i = 0..num_votes-1）
- 候选结束后执行投票：
  - 对各候选 CSV 做结构一致性与同值比较（见 `agent.py::vote_result`），统计“相同答案的数量”，多数获胜。
  - 将胜出候选的 `ilog.log` 复制为标准 `log.log`，对应 SQL/CSV 复制为 `result.sql/result.csv`。
  - 平票时若 `--model_vote` 则调用 LLM 再投（生成 `vote.log`），否则可选 `--random_vote_for_tie` 随机选择或直接返回。

### 4.2 代理执行：agent.py

- 列探索阶段（仅 Step 2 启用）：`exploration()`
  - 从 `prompts.txt` 和问题构造探索提示，生成若干探查 SQL；逐条执行（`[Try to execute]/[Successfully executed]` 记录在 `ilog.log`）。
  - 将探查到的 SQL 与结果拼回到“自我迭代”提示中作为证据。

- 自我迭代（两步均启用）：`self_refine()`
  - 根据表结构、任务、（可选）探索证据，迭代生成一个最终 SQL 并执行。
  - 成功（执行返回码为 '0'）则写 `iresult.sql/iresult.csv`；失败或空结果会尝试纠错，超出 `max_iter`/early stop 则结束该候选。
  - 重要：若 SQL 大量 UNION 多表且超出 Snowflake 会话超时，日志会记录超时错误（不会生成候选结果文件）。

- 直出模式：`gen()`
  - 若未启用自我迭代，可一次生成并执行写结果（本流程中默认使用 `self_refine`）。

### 4.3 模型/对话/提示

- `chat.py::GPTChat`：封装与模型的对话接口，跟踪消息与返回。
- `prompt.py::Prompts`：集中构造提示文案（探索、自我迭代、格式约束、自洽性检查等）。

### 4.4 执行引擎：sql.py

- `SqlEnv` 统一封装执行接口：`execute_sql_api(sql, ex_id, save_path, api=...)`。
  - Snowflake：读取样例目录下复制过来的 `snowflake_credential.json`，通过 `snowflake.connector.connect(**cred)` 建连并游标执行。
  - SQLite/BigQuery：同一接口下分别处理（当前 task=snow 主要用 Snowflake）。
  - 结果按 CSV 写到 `iresult.csv`，供投票与评估使用。

输出物（每样例目录）：
- 候选级：`0..7log.log`、`0..7result.sql`、`0..7result.csv`（成功者存在）
- 最终级：`log.log`（胜出日志副本）、`result.sql`、`result.csv`、（可选）`vote.log`

---

## 5. 评估：eval.py

- 脚本：`eval.py`
- 用法：`python eval.py --log_folder <OUTPUT_PATH> --task snow`
- 机制：
  - 读取 Spider2-Snow 的 gold CSV（位于 `../../spider2-snow/evaluation_suite/gold/exec_result`）。
  - 对每个样例：
    - 若存在最终 `result.csv`，按题目配置（列/顺序容忍度）与 gold 比较，记为最终分。
    - 同时统计候选级的“Pass@k”（至少一条候选匹配 gold 记 1）。
- 输出：在控制台打印每例是否通过与总体统计（最终分/Pass@k）。

---

## 6. 结果打包与官方评测

- `get_metadata.py`：
  - `python get_metadata.py --result_path <OUTPUT_PATH> --output_path output/<MODEL>-snow-csv-<TIME>`
  - 将各样例目录内的 `result.csv` 复制到输出目录，并生成 `results_metadata.jsonl`（提交格式）。
  - 再执行一次以 `--file_type sql` 复制 `result.sql` 到 `output/<MODEL>-snow-sql-<TIME>`。

- 官方评测：
  - 切换到 `../../spider2-snow/evaluation_suite`
  - 运行 `python evaluate.py --mode exec_result --result_dir ../../methods/ReFoRCE/output/<MODEL>-snow-csv-<TIME>`
  - 输出 Spider2 官方评分结果。

---

## 与运行相关的关键参数与行为总结

- 投票与重跑：
  - `--do_vote --num_votes 8`：每样例 8 个候选并发执行；投票从候选 CSV 的“同答案数量”决定胜者。
  - `--rerun`：仅当某候选已有 `iresult.sql` 时跳过该候选；
  - `--overwrite_unfinished`：若最终 `result.sql` 不存在，清空样例目录后重跑全部候选（因此所有 `xlog.log` 都会从 `[Exploration]` 开始）。

- 列探索：
  - `--do_column_exploration` 开启 `[Exploration]`，先以小 SQL 探查表/列与值，再把证据拼入自我迭代提示。

- Schema Linking：
  - `schema_linking.py` 根据 `linked_*.json` 过滤/裁剪表与列，输出 `DDL_sl.csv`；随后调用 `reconstruct_data.compress_ddl(..., schema_linked=True)` 重新生成更短的 prompts。

- Snowflake 超时与性能：
  - 若生成的 SQL 对数百张日表做 UNION/聚合，可能触发会话/仓库超时（默认 120s），导致候选不产出结果文件。
  - 可在 `snowflake_credential.json` 中设置 `session_parameters.STATEMENT_TIMEOUT_IN_SECONDS`、增大 `warehouse` 规格或调整提示以减少表扫描量。

---

## 常见问题（FAQ）

- 为什么目录里有 `0..7log.log` 却没有 `result.*`？
  - 所有候选在自我迭代阶段执行失败/超时，未产出 `iresult.csv/.sql`，因此无法投票/汇总。

- 为什么有的 `xlog.log` 有 `[Exploration]` 有的没有？
  - 仅 Step 2 开启列探索；如果 Step 2 之前存在候选级 `iresult.sql` 且仅 `--rerun` 则该候选会跳过而不产生 Exploration 日志。
  - 若同时使用 `--overwrite_unfinished` 且该样例还没有 `result.sql`，会先清空目录，导致所有候选重新执行探索阶段（因此每个 `xlog.log` 都会有 `[Exploration]`）。

- `These two schemas are not the same ...` 打印是什么？
  - `reconstruct_data.py` 在 `--rm_digits` 模式下，将去数字后的同前缀表聚类，对比代表表与同组表的列集合是否一致，仅提示不终止。

---

## 产物目录结构示例（每个样例）

```
output/<MODEL>-snow-log-<TIME>/<instance_id>/
  ├─ 0log.log ... 7log.log        # 候选执行日志
  ├─ 0result.sql/.csv ...         # 候选 SQL 与结果（成功者存在）
  ├─ log.log                      # 胜出候选的日志副本（投票后生成）
  ├─ result.sql                   # 胜出候选 SQL（投票后生成）
  ├─ result.csv                   # 胜出候选结果（投票后生成）
  └─ vote.log                     # 若启用 --model_vote 则生成
```

---

## 参考文件与入口

- Shell：`scripts/run_main.sh`
- 核心脚本：
  - 准备：`spider_agent_setup_snow.py`
  - 压缩：`reconstruct_data.py`
  - Linking：`schema_linking.py`
  - 运行：`run.py`、`agent.py`、`chat.py`、`prompt.py`、`sql.py`
  - 评估：`eval.py`、`spider2-snow/evaluation_suite/evaluate.py`
  - 打包：`get_metadata.py`
