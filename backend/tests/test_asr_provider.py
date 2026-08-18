import json
from pathlib import Path

import httpx
import pytest


def _completed_result_response() -> dict[str, object]:
    first_sentence = {
        "st": {
            "bg": "0",
            "ed": "1200",
            "rt": [
                {
                    "ws": [
                        {"cw": [{"w": "你好", "wp": "n"}]},
                        {"cw": [{"w": "，", "wp": "p"}]},
                        {"cw": [{"w": "会议开始", "wp": "n"}]},
                    ]
                }
            ],
        }
    }
    second_sentence = {
        "st": {
            "bg": "1200",
            "ed": "2500",
            "rt": [
                {
                    "ws": [
                        {"cw": [{"w": "。", "wp": "p"}]},
                    ]
                }
            ],
        }
    }
    order_result = {
        "lattice": [
            {"json_1best": json.dumps(first_sentence, ensure_ascii=False)},
            {"json_1best": json.dumps(second_sentence, ensure_ascii=False)},
        ]
    }
    return {
        "code": "000000",
        "descInfo": "success",
        "content": {
            "orderInfo": {
                "status": 4,
                "orderId": "test-order-id",
                "failType": 0,
            },
            "orderResult": json.dumps(order_result, ensure_ascii=False),
            "taskEstimateTime": 1000,
        },
    }


def test_real_provider_uploads_media_polls_and_returns_plain_text(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.asr.real import RealASRProvider

    media_path = tmp_path / "测试会议.mp4"
    media_content = b"test-media-content"
    media_path.write_bytes(media_content)
    monkeypatch.setenv("ASR_APP_ID", "test-app")
    monkeypatch.setenv("ASR_SECRET_KEY", "test-secret")
    sleeps: list[float] = []
    requests: list[httpx.Request] = []

    def handle_request(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.url.params["appId"] == "test-app"
        assert request.url.params["ts"] == "1700000000"
        assert request.url.params["signa"] == "8wjxrxZbXf4XSSSzU0OTCfNHnFw="

        if request.url.path.endswith("/upload"):
            assert request.method == "POST"
            assert request.headers["content-type"] == "application/octet-stream"
            assert request.headers["content-length"] == str(len(media_content))
            assert "transfer-encoding" not in request.headers
            assert request.url.params["fileName"] == "测试会议.mp4"
            assert request.url.params["fileSize"] == str(len(media_content))
            assert request.url.params["duration"] == "1"
            assert request.read() == media_content
            return httpx.Response(
                200,
                json={
                    "code": "000000",
                    "descInfo": "success",
                    "content": {
                        "orderId": "test-order-id",
                        "taskEstimateTime": 1000,
                    },
                },
            )

        assert request.url.path.endswith("/getResult")
        assert request.method == "GET"
        assert request.url.params["orderId"] == "test-order-id"
        if len(requests) == 2:
            return httpx.Response(
                200,
                json={
                    "code": "000000",
                    "descInfo": "success",
                    "content": {
                        "orderInfo": {
                            "status": 3,
                            "orderId": "test-order-id",
                            "failType": 0,
                        },
                        "taskEstimateTime": 1000,
                    },
                },
            )
        return httpx.Response(200, json=_completed_result_response())

    provider = RealASRProvider(
        transport=httpx.MockTransport(handle_request),
        sleep=sleeps.append,
        now=lambda: 1700000000,
    )

    transcript = provider.transcribe(str(media_path))

    assert transcript == "你好，会议开始。"
    assert [request.url.path for request in requests] == [
        "/v2/api/upload",
        "/v2/api/getResult",
        "/v2/api/getResult",
    ]
    assert sleeps == [5.0]


def test_real_provider_requires_credentials_from_environment(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.asr.base import ASRProviderError
    from app.providers.asr.real import RealASRProvider

    media_path = tmp_path / "meeting.mp3"
    media_path.write_bytes(b"audio")
    monkeypatch.delenv("ASR_APP_ID", raising=False)
    monkeypatch.delenv("ASR_SECRET_KEY", raising=False)

    with pytest.raises(
        ASRProviderError,
        match="ASR_APP_ID and ASR_SECRET_KEY must be configured",
    ):
        RealASRProvider().transcribe(str(media_path))


def test_real_provider_converts_vendor_order_failure_to_clear_error(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.asr.base import ASRProviderError
    from app.providers.asr.real import RealASRProvider

    media_path = tmp_path / "meeting.mp3"
    media_path.write_bytes(b"audio")
    monkeypatch.setenv("ASR_APP_ID", "test-app")
    monkeypatch.setenv("ASR_SECRET_KEY", "test-secret")

    def handle_request(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/upload"):
            return httpx.Response(
                200,
                json={
                    "code": "000000",
                    "descInfo": "success",
                    "content": {"orderId": "failed-order"},
                },
            )
        return httpx.Response(
            200,
            json={
                "code": "000000",
                "descInfo": "success",
                "content": {
                    "orderInfo": {
                        "status": -1,
                        "orderId": "failed-order",
                        "failType": 6,
                    }
                },
            },
        )

    provider = RealASRProvider(
        transport=httpx.MockTransport(handle_request),
        sleep=lambda _: None,
        now=lambda: 1700000000,
    )

    with pytest.raises(
        ASRProviderError,
        match=r"XFYun ASR order failed \(fail type 6: silent media\)",
    ):
        provider.transcribe(str(media_path))


def test_real_provider_hides_signed_url_when_network_request_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.asr.base import ASRProviderError
    from app.providers.asr.real import RealASRProvider

    media_path = tmp_path / "meeting.mp3"
    media_path.write_bytes(b"audio")
    monkeypatch.setenv("ASR_APP_ID", "test-app")
    monkeypatch.setenv("ASR_SECRET_KEY", "test-secret")

    def fail_request(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("network unavailable", request=request)

    provider = RealASRProvider(
        transport=httpx.MockTransport(fail_request),
        now=lambda: 1700000000,
    )

    with pytest.raises(ASRProviderError) as error:
        provider.transcribe(str(media_path))

    message = str(error.value)
    assert message == "XFYun ASR upload request failed"
    assert "signa" not in message
    assert "test-secret" not in message
    assert error.value.__cause__ is None


def test_provider_factory_selects_mock_or_xfyun_from_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.asr.factory import get_asr_provider
    from app.providers.asr.mock import MockASRProvider
    from app.providers.asr.real import RealASRProvider

    monkeypatch.setenv("ASR_PROVIDER", "mock")
    assert isinstance(get_asr_provider(), MockASRProvider)

    monkeypatch.setenv("ASR_PROVIDER", "xfyun")
    assert isinstance(get_asr_provider(), RealASRProvider)


def test_provider_factory_rejects_unknown_provider(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.providers.asr.base import ASRProviderError
    from app.providers.asr.factory import get_asr_provider

    monkeypatch.setenv("ASR_PROVIDER", "unknown")

    with pytest.raises(ASRProviderError, match="Unsupported ASR provider: unknown"):
        get_asr_provider()
