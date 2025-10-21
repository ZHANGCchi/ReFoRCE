## linked*.json
由`methods/ReFoRCE/schema_linking.py`生成的文件的表级模式链接。

## omnisql*.json
我们遵循[OmniSQL](https://github.com/RUCKBReasoning/OmniSQL)的提示格式和评估脚本。

**omnisql_spider2_sqlite_OS_linked.json**：我们应用[OpenSearchSQL](https://github.com/OpenSearch-AI/OpenSearch-SQL)的提取部分来创建此文件。

### 格式及使用方法

当传递`--omnisql_format_pth`给`methods/ReFoRCE/run.py`时，有两种典型的OmniSQL JSON格式：

- 对于SQLite/本地示例（当`--subtask sqlite`时）：每个条目应包含
	- `instance_id`：字符串，以`local`开头（例如，`local002`）
	- `question`：自然语言查询
	- `db_desc`：数据库模式/指令文本（可以嵌入少量示例块，如"Query:"/"Answer:"）
	- `db_id`：sqlite数据库名称（用于定位`{db_id}.sqlite`）

	在`run.py`中，这些字段将按原样使用。`db_desc`将用作整个表信息提示。

- 对于Spider/BIRD任务（当`--task spider`或`--task BIRD`时）：每个条目应包含
	- `question_id`：整数ID（用于创建`instance_id = local_{task}_{id:04d}`）
	- `question`：自然语言查询
	- `input_seq`：数据库模式/指令文本（可以嵌入少量示例块）
	- `db_id`：数据库名称
	- `SQL`：黄金SQL（用于生成用于评估的黄金CSV）

	在`run.py`中，`input_seq`将用作整个表信息提示。`SQL`将执行以生成黄金结果（除非您修改代码以跳过黄金生成）。

代码期望的SQLite路径约定：
	- Spider：`../../data/spider/test_database/{db_id}/{db_id}.sqlite`
	- BIRD：`../../data/BIRD/dev_databases/{db_id}/{db_id}.sqlite`

如果您的实际路径不同，请适应它们或修改`utils.get_sqlite_path`。

### 与`reconstruct_data.py`的提示构建差异

当提供`--omnisql_format_pth`时，提示构建与使用`reconstruct_data.py`生成的本地`prompts.txt`不同：

- `reconstruct_data.py`为每个示例文件夹编写`prompts.txt`，其中包含诸如"Table full name:"、"Column name:"、可选的"Sample rows:"，然后附加摘要"The table structure information is ..."。当没有提供OmniSQL JSON时，`run.py`通过`utils.get_table_info`读取这些内容。

- 使用OmniSQL JSON时：
	- 对于`task=lite`（SQLite），`Prompts.get_self_refine_prompt`将内容包装在OmniSQL风格的输入模板（引擎+模式+问题）中以指导生成。
	- 对于`task in {BIRD, spider}`，代码直接使用`input_seq`字符串（加上可选的列探索少量示例）作为完整提示，而无需额外的包装。

这意味着两种模式之间的提示表面有意不同。如果您的JSON已经在`db_desc`/`input_seq`中包含了少量示例，它们将原样流入最终提示。

### 最小JSON示例

- SQLite/本地：
	{
		"instance_id": "local002",
		"question": "...",
		"db_desc": "CREATE TABLE ...\n...（可选的少量Query/Answer块）...",
		"db_id": "E_commerce"
	}

- Spider/BIRD：
	{
		"question_id": 1,
		"question": "...",
		"input_seq": "The table structure information is ...",
		"db_id": "database_1",
		"SQL": "SELECT ..."  
	}

注意：对于Spider/BIRD，如果没有`SQL`（黄金），当前的`run.py`期望生成黄金CSV。如果需要，您可以添加一个标志并跳过该块。