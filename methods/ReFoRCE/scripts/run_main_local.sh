#!/bin/bash
# 说明：
# 本脚本用于在本地只运行 spider2 的 lite（SQLite）子任务的完整流水线。
# 主要步骤：
# 1) 参数解析与环境设置（仅允许 --task lite；可选 --azure 模式，选择模型 --model）
# 2) 检查/解压本地 SQLite 数据集 local_sqlite.zip（若已存在 *.sqlite 则跳过）
# 3) 生成 examples（样例数据文件夹），再筛选出仅包含本地数据库的样例
# 4) reconstruct_data.py 补充描述/示例行等，schema_linking.py 做模式链接
# 5) run.py + eval.py 三/四个阶段的生成与评估（自我修正 + 多轮投票 + tie 随机打破 + final choose）
# 6) get_metadata.py 汇总导出 CSV/SQL；若有 CSV 则调用官方 evaluator（无则跳过，避免除零错误）
set -e
set -o pipefail

# Enable bash trace when VERBOSE=1 (export VERBOSE=1)
if [ "${VERBOSE:-0}" = "1" ]; then
  set -x
fi
# TIMESTAMP：区分本次运行产生的输出目录
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
# AZURE 标志：当传入 --azure 时开启 Azure OpenAI 模式
AZURE=false
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --azure)
      AZURE=true
      shift # past argument
      ;;
    --task)
      TASK="$2"
      shift
      shift
      ;;
    --model)
      API="$2"
      shift
      shift
      ;;
    *)
      shift
      ;;
  esac
done


# Force UTF-8 and suppress noisy warnings
# 统一 Python 编码与屏蔽部分不必要的警告，避免中文/日志乱码与噪声
export PYTHONUTF8=1
export PYTHONIOENCODING=UTF-8
export PYTHONWARNINGS=ignore

# # Default to lite and hard-enforce lite-only local run
# # 仅允许运行 lite 任务；若未显式传入 --task，则默认 lite
# if [ -z "${TASK:-}" ]; then
#   TASK="lite"
# fi
# if [ "$TASK" != "lite" ]; then
#   echo "[run_main_local] This script is designed to run ONLY the 'lite' task with local SQLite databases."
#   echo "[run_main_local] Detected task='$TASK'. Please pass: --task lite"
#   exit 1
# fi

# # Setup only when TASK is lite (ensure local sqlite pack is unzipped)
# # 准备 lite 任务所需的本地 SQLite 数据：
# # - 若 DB 目录已有 *.sqlite 则跳过解压
# # - 否则要求 ../../spider2-lite/resource/local_sqlite.zip 存在并解压
# if [ "$TASK" = "lite" ]; then
#   ZIP_DIR=../../spider2-lite/resource
#   ZIP_FILE="$ZIP_DIR/local_sqlite.zip"
#   DB_DIR=../../spider2-lite/resource/databases/spider2-localdb
#   mkdir -p "$ZIP_DIR" "$DB_DIR"

#   # Skip unzip if sqlite files already exist
#   if compgen -G "$DB_DIR/*.sqlite" > /dev/null; then
#     echo "[run_main_local] Found existing SQLite DBs under $DB_DIR, skip unzip."
#   else
#     if [ ! -f "$ZIP_FILE" ]; then
#       echo "[run_main_local] ERROR: $ZIP_FILE not found."
#       echo "[run_main_local] Please place local_sqlite.zip under $ZIP_DIR and re-run."
#       exit 1
#     fi
#     echo "[run_main_local] Preparing to unzip: $ZIP_FILE"
#     if command -v du >/dev/null 2>&1; then
#       echo "[run_main_local] ZIP size: $(du -h "$ZIP_FILE" | awk '{print $1}')"
#     fi
#     if command -v unzip >/dev/null 2>&1; then
#       FILE_COUNT=$(unzip -Z1 "$ZIP_FILE" | wc -l || echo 0)
#       echo "[run_main_local] ZIP contains ~$FILE_COUNT files. Target dir: $DB_DIR"
#     fi
#     echo "[run_main_local] Unzipping local_sqlite.zip to $DB_DIR ..."
#     # Use timeout if available to avoid indefinite hang
#     # 使用 timeout 限制解压最长 300s，防止解压过程卡死
#     if command -v timeout >/dev/null 2>&1; then
#       timeout 300 unzip -o "$ZIP_FILE" -d "$DB_DIR"
#       UNZIP_RC=$?
#       if [ $UNZIP_RC -eq 124 ]; then
#         echo "[run_main_local] ERROR: unzip timed out after 300s." && exit 1
#       elif [ $UNZIP_RC -ne 0 ]; then
#         echo "[run_main_local] ERROR: unzip failed with code $UNZIP_RC." && exit 1
#       fi
#     else
#       unzip -o "$ZIP_FILE" -d "$DB_DIR"
#     fi
#     DB_COUNT=$(ls -1 "$DB_DIR"/*.sqlite 2>/dev/null | wc -l || echo 0)
#     echo "[run_main_local] Unzip completed. Found $DB_COUNT sqlite files."
#   fi
# fi

# # Ensure placeholder credentials exist to avoid setup errors when running local-only
# # 某些脚本会读取 BigQuery/Snowflake 凭证；为本地-only 场景写入空白占位，避免报错
# if [ "$TASK" = "lite" ]; then
#   [ -f bigquery_credential.json ] || echo "{}" > bigquery_credential.json
#   [ -f snowflake_credential.json ] || echo "{}" > snowflake_credential.json
# fi

# # Generate examples (full)
# # 生成完整 examples（包含非本地与本地）。随后我们会筛选为仅本地子集
# echo "[run_main_local] Generating examples for task=$TASK ..."
# python spider_agent_setup_${TASK}.py --example_folder examples_${TASK}
# echo "[run_main_local] Generated examples at examples_${TASK}"

# # Backup (copy) and build a local-only subset BEFORE reconstruction (avoid mv issues on Windows)
# # 备份一份完整 examples，然后只拷贝 local* 前缀的目录到 examples_${TASK}_local，实现“仅本地”的样例集
# rm -rf examples_${TASK}_full || true
# cp -r examples_${TASK} examples_${TASK}_full || true

# rm -rf examples_${TASK}_local || true
# mkdir -p examples_${TASK}_local

# for d in examples_${TASK}/local*; do
#   if [ -d "$d" ]; then
#     cp -r "$d" examples_${TASK}_local/
#   fi
# done
# LOCAL_DIR_COUNT=$(find examples_${TASK}_local -maxdepth 1 -type d -name 'local*' | wc -l || echo 0)
# echo "[run_main_local] Copied $LOCAL_DIR_COUNT local* example directories into examples_${TASK}_local"

# # copy jsonl manifest for get_dictionary
# # 拷贝 jsonl 清单文件，后续 get_dictionary 等步骤需要用到
# if [ -f examples_${TASK}/spider2-lite.jsonl ]; then
#   cp examples_${TASK}/spider2-lite.jsonl examples_${TASK}_local/
# elif [ -f examples_${TASK}_full/spider2-lite.jsonl ]; then
#   cp examples_${TASK}_full/spider2-lite.jsonl examples_${TASK}_local/
# fi

# # Filter manifest to only keep local instances to avoid referencing non-local DBs
# # 过滤 jsonl，只保留 instance_id 以 local 开头的条目，确保不引用云端数据库
# if [ -f examples_${TASK}_local/spider2-lite.jsonl ]; then
#   echo "[run_main_local] Filtering manifest to local-only instances..."
#   grep -E '"instance_id"[[:space:]]*:[[:space:]]*"local' examples_${TASK}_local/spider2-lite.jsonl > examples_${TASK}_local/spider2-lite.local.jsonl || true
#   if [ -s examples_${TASK}_local/spider2-lite.local.jsonl ]; then
#     mv examples_${TASK}_local/spider2-lite.local.jsonl examples_${TASK}_local/spider2-lite.jsonl
#     echo "[run_main_local] Manifest filtered. Line count: $(wc -l < examples_${TASK}_local/spider2-lite.jsonl)"
#   else
#     echo "[run_main_local] Warning: No local instances found in manifest after filtering."
#   fi
# fi

# # Replace original with local-only subset
# # 用仅本地的 examples 覆盖默认 examples 路径（后续所有步骤都只对本地子集操作）
# rm -rf examples_${TASK}
# mv examples_${TASK}_local examples_${TASK}
# echo "[run_main_local] Using local-only subset at examples_${TASK}"

# # Reconstruct data (now only local subset)
# # 数据重构：添加表/列描述、示例行，清理长样例描述等；会产生 prompts.txt 等文件
# echo "[run_main_local] Reconstructing data (add description/sample rows)..."
# python reconstruct_data.py \
#     --example_folder examples_${TASK} \
#     --add_description \
#     --add_sample_rows \
#     --rm_digits \
#     --make_folder \
#     --clear_long_eg_des
# echo "[run_main_local] Reconstruction done."

# echo "Number of prompts.txt files in examples_${TASK} larger than 200KB before reducing: $(find examples_${TASK} -type f -name \"prompts.txt\" -exec du -b {} + | awk '$1 > 200000' | wc -l)"

# # Schema linking on the local-only subset
# # 模式链接：生成列/表到自然语言的链接信息，写入 data/linked_${TASK}_tmp0.json
# echo "[run_main_local] Starting schema linking..."
# python schema_linking.py \
#     --task $TASK \
#     --db_path examples_${TASK} \
#     --linked_json_pth ../../data/linked_${TASK}_tmp0.json \
#     --reduce_col
# echo "[run_main_local] Schema linking finished. Linked JSON at ../../data/linked_${TASK}_tmp0.json"

# echo "Number of prompts.txt files in examples_${TASK} larger than 200KB before reducing: $(find examples_${TASK} -type f -name \"prompts.txt\" -exec du -b {} + | awk '$1 > 200000' | wc -l)"

# 输出目录与并发/投票参数设置
OUTPUT_PATH="output/${API}-${TASK}-local-log-${TIMESTAMP}"
NUM_VOTES=8
NUM_WORKERS=16
echo "AZURE mode: $AZURE"
echo "Model: $API"
echo "Task: $TASK"
echo "Output Path: $OUTPUT_PATH"

# Step 1: Self-refinement + Majority Voting (local-only)
# 第一步：自我修正 + 多轮生成 + 多数投票；会在 $OUTPUT_PATH 下记录日志与中间结果
CMD1="python run.py \
    --task $TASK \
    --subtask sqlite \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_self_refinement \
    --generation_model ${API} \
    --max_iter 5 \
    --temperature 1 \
    --early_stop \
    --do_vote \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS"

# Step 2: + Column Exploration + Rerun (local-only)
# 第二步：在第 1 步基础上加入列探索（column exploration），并对未完成的样例重跑
CMD2="python run.py \
    --task $TASK \
    --subtask sqlite \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_self_refinement \
    --generation_model ${API} \
    --do_column_exploration \
    --column_exploration_model ${API} \
    --max_iter 5 \
    --temperature 1 \
    --early_stop \
    --do_vote \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS \
    --rerun \
    --overwrite_unfinished"

if [ "$AZURE" = true ]; then
  CMD1="$CMD1 --azure"
  CMD2="$CMD2 --azure"
fi

echo "[run_main_local] Step 1 running..."
eval $CMD1
echo "Evaluation for Step 1"
python eval.py --log_folder $OUTPUT_PATH --task $TASK

echo "[run_main_local] Step 2 running..."
eval $CMD2
echo "Evaluation for Step 2"
python eval.py --log_folder $OUTPUT_PATH --task $TASK

# Step 3: Random vote for tie (local-only)
# 第三步：若投票出现平票（tie），进行一次随机打破并评估
echo "[run_main_local] Step 3 running (random vote for tie)..."
python run.py \
    --task $TASK \
    --subtask sqlite \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_vote \
    --random_vote_for_tie \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS
echo "Evaluation for Step 3"
python eval.py --log_folder $OUTPUT_PATH --task $TASK

# Step 4: Random vote final_choose (local-only)
# 第四步：最终选择（final choose）阶段，并再次评估
echo "[run_main_local] Step 4 running (final choose)..."
python run.py \
    --task $TASK \
    --subtask sqlite \
    --db_path examples_${TASK} \
    --output_path $OUTPUT_PATH \
    --do_vote \
    --random_vote_for_tie \
    --final_choose \
    --num_votes $NUM_VOTES \
    --num_workers $NUM_WORKERS
echo "Evaluation for Step 4"
python eval.py --log_folder $OUTPUT_PATH --task $TASK

# Final evaluation and get files for submission (local-only results)
# 汇总导出：将 $OUTPUT_PATH 下的最终结果提取为 CSV/SQL，分别放在新目录下
CSV_DIR="output/${API}-${TASK}-local-csv-${TIMESTAMP}"
SQL_DIR="output/${API}-${TASK}-local-sql-${TIMESTAMP}"
echo "[run_main_local] Collecting submission artifacts (CSV/SQL)..."
python get_metadata.py --result_path $OUTPUT_PATH --output_path "$CSV_DIR"
python get_metadata.py --result_path $OUTPUT_PATH --output_path "$SQL_DIR" --file_type sql
CSV_COUNT=$(ls -1 "$CSV_DIR"/*.csv 2>/dev/null | wc -l || echo 0)
echo "[run_main_local] Submission CSVs: $CSV_COUNT at $CSV_DIR"

# Guard: skip external evaluation if no CSVs to avoid division-by-zero in evaluator
# 若没有生成 CSV（通常是因为模型调用失败或无结果），则跳过官方评测器，避免 ZeroDivisionError
if compgen -G "$CSV_DIR/*.csv" > /dev/null; then
  echo "[run_main_local] Found submission CSVs. Running external evaluator..."
  (cd ../../spider2-${TASK}/evaluation_suite && python evaluate.py --mode exec_result --result_dir ../../methods/ReFoRCE/$CSV_DIR) || echo "[run_main_local] External evaluator exited with non-zero status. This can happen in lite-local mode if IDs don't overlap with gold."
else
  echo "[run_main_local] No submission CSVs found under $CSV_DIR. Skipping external evaluator to avoid ZeroDivisionError."
  echo "[run_main_local] You can re-run the evaluator later once results are generated:"
  echo "(cd ../../spider2-${TASK}/evaluation_suite && python evaluate.py --mode exec_result --result_dir ../../methods/ReFoRCE/$CSV_DIR)"
fi
