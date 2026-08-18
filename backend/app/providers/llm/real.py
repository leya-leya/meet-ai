import os

import httpx

from app.providers.llm.base import LLMProvider, LLMProviderError


REQUIRED_HEADINGS = (
    "## 内容摘要",
    "## 核心要点",
    "## 待办事项",
)

SYSTEM_PROMPT = """你是企业内部会议与音视频内容整理助手。
你的任务是忠实整理输入文本，不虚构输入中不存在的信息。
输出必须使用简体中文 Markdown。"""

USER_PROMPT_TEMPLATE = """请根据以下转写文本生成结构化摘要。

要求：
1. 保留事实，不虚构。
2. 输出必须包含以下三个二级标题：
   ## 内容摘要
   ## 核心要点
   ## 待办事项
3. 内容摘要控制在数段以内。
4. 核心要点使用项目符号。
5. 只有文本中存在明确行动项时才提取待办；
   如果没有明确待办，写“无明确待办事项”。
6. 不要输出额外说明。

转写文本：
{transcript}"""


class RealLLMProvider(LLMProvider):
    def __init__(
        self,
        *,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._transport = transport

    def summarize(self, transcript: str) -> str:
        normalized_transcript = transcript.strip()
        if not normalized_transcript:
            raise LLMProviderError("Transcript must not be empty")

        api_key = os.getenv("LLM_API_KEY", "").strip()
        base_url = os.getenv("LLM_BASE_URL", "").strip().rstrip("/")
        model = os.getenv("LLM_MODEL", "").strip()
        if not api_key or not base_url or not model:
            raise LLMProviderError(
                "LLM_API_KEY, LLM_BASE_URL, and LLM_MODEL must be configured"
            )

        timeout = httpx.Timeout(120.0, connect=10.0)
        with httpx.Client(
            transport=self._transport,
            timeout=timeout,
        ) as client:
            try:
                response = client.post(
                    f"{base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {api_key}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "model": model,
                        "messages": [
                            {"role": "system", "content": SYSTEM_PROMPT},
                            {
                                "role": "user",
                                "content": USER_PROMPT_TEMPLATE.format(
                                    transcript=normalized_transcript
                                ),
                            },
                        ],
                        "stream": False,
                    },
                )
            except httpx.HTTPError:
                raise LLMProviderError(
                    "DeepSeek LLM request failed"
                ) from None

        if not response.is_success:
            raise LLMProviderError(
                f"DeepSeek LLM request failed (HTTP {response.status_code})"
            )

        try:
            payload = response.json()
        except (ValueError, UnicodeDecodeError) as exc:
            raise LLMProviderError(
                "DeepSeek LLM returned invalid JSON"
            ) from exc

        try:
            summary = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise LLMProviderError(
                "DeepSeek LLM returned an invalid response"
            ) from exc

        if not isinstance(summary, str) or not summary.strip():
            raise LLMProviderError("DeepSeek LLM returned an empty summary")
        normalized_summary = summary.strip()
        if any(heading not in normalized_summary for heading in REQUIRED_HEADINGS):
            raise LLMProviderError(
                "DeepSeek LLM summary is missing required headings"
            )
        return normalized_summary
