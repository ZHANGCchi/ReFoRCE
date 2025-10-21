# Spider 2.0-snow

为了与**传统的文本到SQL设置**的研究兴趣相一致，以及**使评估更加方便**，我们已经将Spider 2.0中非DBT项目中使用的所有数据库托管在Snowflake上（感谢Snowflake的支持！）。在这种设置中，用户只需要使用单一的SQL语言完成任务，使文本到SQL的研究更加专注。

## 🚀 快速开始

1. **Snowflake账户**：按照此[指南](https://github.com/xlang-ai/Spider2/blob/main/assets/Snowflake_Guideline.md)获取您自己的Snowflake用户名和密码在我们的snowflake数据库中。您必须更新`bigquery_credential.json`和`snowflake_credential.json`。

2. 更新`bigquery_credential.json`和`snowflake_credential.json`。

### 运行 Spider-Agent(Snow)

1. **安装Docker**。按照[Docker设置指南](https://docs.docker.com/engine/install/)中的说明在您的计算机上安装Docker。
2. **安装conda环境**。
```
git clone https://github.com/xlang-ai/Spider2.git
cd methods/spider-agent-snow

# 可选：为Spider 2.0创建一个Conda环境
# conda create -n spider2 python=3.11
# conda activate spider2

# 安装所需依赖
pip install -r requirements.txt
```
3. **配置凭证**：按照此[指南](https://github.com/xlang-ai/Spider2/blob/main/assets/Snowflake_Guideline.md)获取您自己的Snowflake用户名和密码在我们的snowflake数据库中。您必须更新`snowflake_credential.json`。

4. **Spider 2.0-Snow 设置**
```
python spider_agent_setup_snow.py
```

5. **运行代理**
```
export OPENAI_API_KEY=your_openai_api_key
python run.py --model gpt-4o -s test1
```

### 在Spider2-Snow上运行DAIL-SQL

1. 将`spider2-lite/baselines/dailsql`文件夹复制到`spider-snow/baselines/dailsql`。

2. 在`spider-snow/baselines/dailsql/run.sh`中将`DEV=spider2-lite`更改为`DEV=spider2-snow`。

3. 以与`spider-lite`相同的方式在`spider2-snow`上运行DAIL-SQL。

## 评估

```
python get_spider2snow_submission_data.py --experiment_suffix gpt-4o-test1 --results_folder_name ../../spider2-snow/evaluation_suite/gpt-4o-test1

cd ../../spider2-snow/evaluation_suite
python evaluate.py --mode exec_result --result_dir gpt-4o-test1
```