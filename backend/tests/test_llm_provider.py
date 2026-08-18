import json

import httpx
import pytest


VALID_SUMMARY = """## 内容摘要

本次会议确认了项目验收安排。

## 核心要点

- 核心功能已经完成
- 下周进行验收

## 待办事项

- 项目负责人准备验收材料
"""


def _set_deepseek_config(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LLM_API_KEY", "test-deepseek-key")
    monkeypatch.setenv("LLM_BASE_URL", "https://api.deepseek.com")
    monkeypatch.setenv("LLM_MODEL", "deepseek-v4-flash")


def test_real_provider_sends_fixed_prompt_and_returns_markdown_summary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.real import RealLLMProvider

    _set_deepseek_config(monkeypatch)
    requests: list[httpx.Request] = []

    def handle_request(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        payload = json.loads(request.content)
        assert request.method == "POST"
        assert request.url == "https://api.deepseek.com/chat/completions"
        assert request.headers["authorization"] == "Bearer test-deepseek-key"
        assert payload["model"] == "deepseek-v4-flash"
        assert payload["stream"] is False
        assert payload["messages"][0]["role"] == "system"
        assert "不虚构" in payload["messages"][0]["content"]
        assert payload["messages"][1]["role"] == "user"
        assert "## 内容摘要" in payload["messages"][1]["content"]
        assert "## 核心要点" in payload["messages"][1]["content"]
        assert "## 待办事项" in payload["messages"][1]["content"]
        assert "这是需要总结的真实转写文本。" in payload["messages"][1]["content"]
        return httpx.Response(
            200,
            json={
                "id": "completion-id",
                "choices": [
                    {
                        "index": 0,
                        "finish_reason": "stop",
                        "message": {
                            "role": "assistant",
                            "content": VALID_SUMMARY,
                        },
                    }
                ],
                "created": 1787040000,
                "model": "deepseek-v4-flash",
                "object": "chat.completion",
                "usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 50,
                    "total_tokens": 150,
                },
            },
        )

    provider = RealLLMProvider(transport=httpx.MockTransport(handle_request))

    summary = provider.summarize("这是需要总结的真实转写文本。")

    assert summary == VALID_SUMMARY.strip()
    assert len(requests) == 1


def test_real_provider_requires_non_empty_transcript(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.real import RealLLMProvider

    _set_deepseek_config(monkeypatch)

    with pytest.raises(LLMProviderError, match="Transcript must not be empty"):
        RealLLMProvider().summarize("   ")


def test_real_provider_requires_environment_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.real import RealLLMProvider

    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.delenv("LLM_MODEL", raising=False)

    with pytest.raises(
        LLMProviderError,
        match="LLM_API_KEY, LLM_BASE_URL, and LLM_MODEL must be configured",
    ):
        RealLLMProvider().summarize("测试转写")


def test_real_provider_hides_credentials_when_network_request_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.real import RealLLMProvider

    _set_deepseek_config(monkeypatch)

    def fail_request(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("network unavailable", request=request)

    provider = RealLLMProvider(transport=httpx.MockTransport(fail_request))

    with pytest.raises(LLMProviderError) as error:
        provider.summarize("测试转写")

    assert str(error.value) == "DeepSeek LLM request failed"
    assert "test-deepseek-key" not in str(error.value)
    assert error.value.__cause__ is None


def test_real_provider_reports_http_status_without_vendor_body(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.real import RealLLMProvider

    _set_deepseek_config(monkeypatch)

    provider = RealLLMProvider(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                401,
                json={"error": {"message": "secret vendor detail"}},
            )
        )
    )

    with pytest.raises(
        LLMProviderError,
        match=r"^DeepSeek LLM request failed \(HTTP 401\)$",
    ):
        provider.summarize("测试转写")


def test_real_provider_rejects_invalid_json_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.real import RealLLMProvider

    _set_deepseek_config(monkeypatch)
    provider = RealLLMProvider(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(200, content=b"not-json")
        )
    )

    with pytest.raises(
        LLMProviderError,
        match="DeepSeek LLM returned invalid JSON",
    ):
        provider.summarize("测试转写")


@pytest.mark.parametrize(
    ("content", "expected_error"),
    [
        ("", "DeepSeek LLM returned an empty summary"),
        (
            "## 内容摘要\n\n只有摘要，没有其他固定段落。",
            "DeepSeek LLM summary is missing required headings",
        ),
        (
            "## 核心要点\n\n- 要点\n\n"
            "## 内容摘要\n\n摘要\n\n"
            "## 待办事项\n\n- 无明确待办事项",
            "DeepSeek LLM summary is missing required headings",
        ),
    ],
)
def test_real_provider_rejects_invalid_heading_structure(
    monkeypatch: pytest.MonkeyPatch,
    content: str,
    expected_error: str,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.real import RealLLMProvider

    _set_deepseek_config(monkeypatch)
    provider = RealLLMProvider(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                200,
                json={
                    "choices": [
                        {"message": {"role": "assistant", "content": content}}
                    ]
                },
            )
        )
    )

    with pytest.raises(LLMProviderError, match=expected_error):
        provider.summarize("测试转写")


def test_provider_factory_selects_mock_or_deepseek_from_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.factory import get_llm_provider
    from app.providers.llm.mock import MockLLMProvider
    from app.providers.llm.real import RealLLMProvider

    monkeypatch.setenv("LLM_PROVIDER", "mock")
    assert isinstance(get_llm_provider(), MockLLMProvider)

    monkeypatch.setenv("LLM_PROVIDER", "deepseek")
    assert isinstance(get_llm_provider(), RealLLMProvider)


def test_provider_factory_rejects_unknown_provider(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.llm.base import LLMProviderError
    from app.providers.llm.factory import get_llm_provider

    monkeypatch.setenv("LLM_PROVIDER", "unknown")

    with pytest.raises(LLMProviderError, match="Unsupported LLM provider: unknown"):
        get_llm_provider()
