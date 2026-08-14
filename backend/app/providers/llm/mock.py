from app.providers.llm.base import LLMProvider


MOCK_SUMMARY = """## 内容摘要

这是一段用于自动化测试的摘要。

## 核心要点

- 测试要点

## 待办事项

- 无明确待办事项
"""


class MockLLMProvider(LLMProvider):
    def summarize(self, transcript: str) -> str:
        return MOCK_SUMMARY
