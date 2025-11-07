import sys
import time
import random
from abc import ABC, abstractmethod
from utils import extract_all_blocks, get_rss_mb

class BaseChat(ABC):
    def __init__(self, model: str, temperature: float = 1.0):
        self.model = model
        self.temperature = float(temperature)
        self.messages = []

    @abstractmethod
    def get_response(self, prompt) -> str:
        pass

    def get_model_response(self, prompt, code_format=None) -> list:
        code_blocks = []
        max_try = 3
        while code_blocks == [] and max_try > 0:
            max_try -= 1
            try:
                response = self.get_response(prompt)
            except Exception as e:
                print(f"max_try: {max_try}, exception: {e}")
                continue
            code_blocks = extract_all_blocks(response, code_format)
        if max_try == 0 or code_blocks == []:
            print(f"get_model_response() exit, max_try: {max_try}, code_blocks: {code_blocks}")
            sys.exit(0)
        return code_blocks

    def get_model_response_txt(self, prompt) -> str:
        max_try = 3
        while max_try > 0:
            max_try -= 1
            try:
                response = self.get_response(prompt)
                return response
            except Exception as e:
                print(f"max_try: {max_try}, exception: {e}")
                continue
        print(f"get_model_response_txt() exit, max_try: {max_try}")
        sys.exit(0)

    def get_message_len(self):
        return {
            "prompt_len": sum(len(item["content"]) for item in self.messages if item["role"] == "user"),
            "response_len": sum(len(item["content"]) for item in self.messages if item["role"] == "assistant"),
            "num_calls": len(self.messages) // 2
        }

    def init_messages(self):
        self.messages = []


from openai import OpenAI, AzureOpenAI
import os
import uuid
import json
import importlib

class GPTChat(BaseChat):
    def __init__(self, azure=False, model="gpt-4o", temperature=0.6):
        super().__init__(model, temperature)
        self.switch = False

        if not azure:
            if model in ["o1-preview", "o1-mini", "Qwen3-Coder-30B-A3B-Instruct", "Qwen3-32B", "Qwen3-14B"]:
                self.client = OpenAI(
                    base_url="http://app-a9f0de88ae8d476fb97a534637d556a8.ns-devsft-7784ec30.svc.cluster.local:9000/v1",
                    api_key="empty",
                )
            elif model in ["deepseek-reasoner"]:
                self.client = OpenAI(
                    base_url="https://api.deepseek.com",
                    api_key=os.environ.get("DS_API_KEY"),
                )
            elif model in ["deepseek-reasoner"]:
                self.client = OpenAI(
                    base_url="https://api.deepseek.com",
                    api_key=os.environ.get("DS_API_KEY"),
                )
            else:
                # self.client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))
                self.switch = True
                api_key = os.environ.get("API_KEY")
                if not api_key:
                    raise RuntimeError("API_KEY environment variable not set")
                # lazy-load proxy client to avoid hard import errors in environments without it
                if not importlib.util.find_spec("openai_proxy"):
                    raise RuntimeError(
                        "openai_proxy not found. Please install gpt_proxy_client and ensure it is importable."
                    )
                openai_proxy = importlib.import_module("openai_proxy")
                # keep self.model as provided by caller (e.g., doubao-Seed-1.6-vision-250815)
                self.subaccount = os.environ.get("SUBACCOUNT", "zhangwenhao")
                self.client = openai_proxy.GptProxy(api_key=api_key)
                # channel_code required by proxy service; default to doubao
                self.channel_code = os.environ.get("CHANNEL_CODE", "doubao")
                self.transaction_id = f"{self.subaccount}-{self.model}-{uuid.uuid4().hex[:8]}"

        else:
            if model in ["o1-preview", "o1-mini", "o3", "o4-mini"]:
                version = "2024-12-01-preview"
            elif model in ["o3-pro"]:
                version = "2025-03-01-preview"
            else:
                version = "2024-05-01-preview"

            self.client = AzureOpenAI(
                azure_endpoint=os.environ.get("AZURE_ENDPOINT"),
                api_key=os.environ.get("AZURE_OPENAI_KEY"),
                api_version=version
            )

    def get_response(self, prompt) -> str:
        self.messages.append({"role": "user", "content": prompt})
        if self.model == "o3-pro":
            response = self.client.responses.create(
                model=self.model,
                input=self.messages,
                temperature=self.temperature
            )
            main_content = response.output_text
        elif self.switch:
            # Use proxy client's generate API (ptu style), and parse JSON payload to text
            response = self.client.generate(
                messages=self.messages,
                model=self.model,
                channel_code=getattr(self, "channel_code", "doubao"),
                transaction_id=self.transaction_id,
                temperature=self.temperature,
            )
            main_content = ""
            try:
                resp_json = response.json()
                ok = getattr(response, "ok", False)
                code = resp_json.get("code")
                # If proxy returns non-success code, raise to let caller retry without polluting history
                if code is not None and code != 10000:
                    raise RuntimeError(f"proxy_error code={code}: {resp_json.get('msg')}")
                if ok and code == 10000:
                    data = resp_json.get("data", {})
                    rc = data.get("response_content", {})
                    choices = rc.get("choices", [])
                    if isinstance(choices, list) and choices:
                        main_content = (
                            choices[0].get("message", {}).get("content")
                            or ""
                        )
                # fallback: some gateways may return OpenAI-like JSON
                if not main_content and isinstance(resp_json, dict):
                    choices = resp_json.get("choices")
                    if isinstance(choices, list) and choices:
                        msg = choices[0].get("message", {})
                        main_content = msg.get("content") or ""
                # If still empty and there is an error message, raise to trigger retry
                if not main_content and resp_json.get("msg"):
                    raise RuntimeError(f"proxy_error: {resp_json.get('msg')}")
            except Exception:
                # last resort: raw text body
                main_content = getattr(response, "text", "")
        else:
            response = self.client.chat.completions.create(
                model=self.model,
                messages=self.messages,
                temperature=self.temperature,
                top_p=0.95,
                extra_body = {
                'chat_template_kwargs': {'enable_thinking': False}
            }
            )
            main_content = response.choices[0].message.content

        self.messages.append({"role": "assistant", "content": main_content})
        return main_content

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Quick test entry for GPTChat")
    parser.add_argument("--model", type=str, default="doubao-seed-1.6-250615", help="Model name, e.g., Qwen3-32B, Qwen3-Coder-30B-A3B-Instruct, o1-mini, gpt-4o")
    parser.add_argument("--azure", action="store_true", help="Use Azure OpenAI endpoint")
    parser.add_argument("--temperature", type=float, default=1.0, help="Sampling temperature")
    parser.add_argument("--prompt", type=str, default="请做个自我介绍", help="Prompt text to send")
    parser.add_argument("--format", type=str, default=None, help="Optional code block format to extract, e.g., sql/csv/plaintext")

    args = parser.parse_args()

    chat = GPTChat(azure=args.azure, model=args.model, temperature=args.temperature)

    try:
        if args.format:
            blocks = chat.get_model_response(args.prompt, code_format=args.format)
            print("\n".join(blocks))
        else:
            print(chat.get_model_response_txt(args.prompt))
    except Exception as e:
        print(f"Error during chat: {e}")