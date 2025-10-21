import requests
import time
import logging
import openai


logger = logging.getLogger(__name__)


class Qwen3_32B:
    def __init__(self):
        pass

    def __call__(self,
                 prompt):
        base_url = "http://10.210.1.23:10000/v1"

        client = openai.OpenAI(
            api_key="empty",
            base_url=base_url,

        )
        response = client.chat.completions.create(
            model="Qwen3-Coder-30B-A3B-Instruct",
            messages=[
                {"role": "user", "content": prompt}],
            max_tokens=8192,
            temperature=0.001,
            top_p=0.9,
            presence_penalty=1.5,
            extra_body = {
                'chat_template_kwargs': {'enable_thinking': True}
            }
        )
        return response.choices[0].message.content


if __name__=='__main__':
    llm = Qwen3_32B()
    prompt = "请做个自我介绍，我想知道你是什么型号的模型，是否支持CoT"
    print(llm(prompt=prompt))