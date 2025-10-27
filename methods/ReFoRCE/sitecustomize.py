"""
Temporary debug hook to print raw model responses when code block extraction fails.

Usage:
  Set environment variable REFORCE_DEBUG_MODEL_RAW=1 before running the pipeline.
  Example (zsh):
    REFORCE_DEBUG_MODEL_RAW=1 API_KEY="$API_KEY" bash methods/ReFoRCE/scripts/run_main.sh --task snow --model gpt-4o-2024-11-20

Notes:
  - This file leverages Python's automatic import of `sitecustomize` if present on sys.path.
  - It does NOT modify repository source files; it monkey-patches at import time only when the env var is enabled.
  - To disable, unset the environment variable or remove this file.
"""

import os
import sys

if os.environ.get("REFORCE_DEBUG_MODEL_RAW") == "1":
    try:
        # Try both import styles depending on how the code is executed
        try:
            from chat import BaseChat  # type: ignore
            from utils import extract_all_blocks  # type: ignore
        except Exception:
            from methods.ReFoRCE.chat import BaseChat  # type: ignore
            from methods.ReFoRCE.utils import extract_all_blocks  # type: ignore

        _orig_get_model_response = BaseChat.get_model_response

        def _debug_get_model_response(self, prompt, code_format=None):  # type: ignore
            code_blocks = []
            max_try = 3
            last_response_text = None
            while code_blocks == [] and max_try > 0:
                max_try -= 1
                try:
                    response = self.get_response(prompt)
                    last_response_text = response
                except Exception as e:
                    import time
                    ctx = getattr(self, 'context_tag', '-')
                    ts = time.strftime('%Y-%m-%d %H:%M:%S')
                    print(f"[{ts}][PB][{ctx}] get_model_response exception, max_try: {max_try}, err: {e}")
                    continue
                code_blocks = extract_all_blocks(response, code_format)
            # Preserve original exit behavior, but print the raw assistant content for debugging
            if max_try == 0 or code_blocks == []:
                import time
                ctx = getattr(self, 'context_tag', '-')
                ts = time.strftime('%Y-%m-%d %H:%M:%S')
                print(f"[{ts}][PB][{ctx}] [DEBUG get_model_response raw assistant content begin]")
                if last_response_text is not None:
                    try:
                        # Limit extremely long outputs to avoid flooding logs
                        preview = last_response_text if len(last_response_text) <= 20000 else last_response_text[:20000] + "\n...[truncated]"
                        print(preview)
                    except Exception:
                        # Ensure we never fail the debug print
                        print("<failed to print response text>")
                else:
                    print("<no response captured>")
                print(f"[{ts}][PB][{ctx}] [DEBUG get_model_response raw assistant content end]")
                print(f"[{ts}][PB][{ctx}] get_model_response exit, max_try: {max_try}, code_blocks: {code_blocks}")
                sys.exit(0)
            return code_blocks

        # Apply monkey patch
        BaseChat.get_model_response = _debug_get_model_response  # type: ignore
        # Optional one-liner to confirm activation once
        print("[sitecustomize] REFORCE_DEBUG_MODEL_RAW active: BaseChat.get_model_response patched")
    except Exception as _e:
        # Fail silently to avoid breaking normal runs if import paths differ
        pass
# REFORCE_DEBUG_MODEL_RAW=1 API_KEY="$API_KEY" bash run_main.sh --task snow --model gpt-4o-2024-11-20