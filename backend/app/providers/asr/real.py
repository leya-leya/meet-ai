import base64
import hashlib
import hmac
import json
import os
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import httpx

from app.providers.asr.base import ASRProvider, ASRProviderError


XFYUN_BASE_URL = "https://raasr.xfyun.cn/v2/api"
POLL_INTERVAL_SECONDS = 5.0
MAX_RESULT_QUERIES = 100
UPLOAD_CHUNK_BYTES = 64 * 1024

FAIL_TYPE_MESSAGES = {
    1: "upload failed",
    2: "media transcoding failed",
    3: "speech recognition failed",
    4: "media duration exceeded the limit",
    5: "media validation failed",
    6: "silent media",
    7: "translation failed",
    8: "translation permission unavailable",
    9: "quality inspection failed",
    10: "quality inspection keyword not found",
    11: "requested capability is not enabled",
    99: "other provider error",
}


class RealASRProvider(ASRProvider):
    def __init__(
        self,
        *,
        transport: httpx.BaseTransport | None = None,
        sleep: Callable[[float], None] = time.sleep,
        now: Callable[[], float] = time.time,
    ) -> None:
        self._transport = transport
        self._sleep = sleep
        self._now = now

    def transcribe(self, file_path: str) -> str:
        media_path = Path(file_path)
        if not media_path.is_file():
            raise FileNotFoundError(f"Media file not found: {file_path}")

        app_id = os.getenv("ASR_APP_ID", "").strip()
        secret_key = os.getenv("ASR_SECRET_KEY", "").strip()
        if not app_id or not secret_key:
            raise ASRProviderError(
                "ASR_APP_ID and ASR_SECRET_KEY must be configured"
            )

        timeout = httpx.Timeout(1800.0, connect=30.0)
        with httpx.Client(
            transport=self._transport,
            timeout=timeout,
        ) as client:
            order_id = self._upload(
                client=client,
                media_path=media_path,
                app_id=app_id,
                secret_key=secret_key,
            )
            return self._poll_result(
                client=client,
                order_id=order_id,
                app_id=app_id,
                secret_key=secret_key,
            )

    def _upload(
        self,
        *,
        client: httpx.Client,
        media_path: Path,
        app_id: str,
        secret_key: str,
    ) -> str:
        file_size = media_path.stat().st_size
        params = self._signed_params(app_id=app_id, secret_key=secret_key)
        params.update(
            {
                "fileName": media_path.name,
                "fileSize": str(file_size),
                "duration": "1",
                "audioMode": "fileStream",
            }
        )
        with media_path.open("rb") as media_file:
            payload = self._request_json(
                client=client,
                method="POST",
                url=f"{XFYUN_BASE_URL}/upload",
                params=params,
                headers={
                    "Content-Type": "application/octet-stream",
                    "Content-Length": str(file_size),
                },
                content=self._file_chunks(media_file),
                phase="upload",
            )
        self._ensure_success(payload=payload, phase="upload")
        content = payload.get("content")
        order_id = content.get("orderId") if isinstance(content, dict) else None
        if not isinstance(order_id, str) or not order_id:
            raise ASRProviderError("XFYun ASR upload returned no order ID")
        return order_id

    def _poll_result(
        self,
        *,
        client: httpx.Client,
        order_id: str,
        app_id: str,
        secret_key: str,
    ) -> str:
        for query_number in range(MAX_RESULT_QUERIES):
            params = self._signed_params(app_id=app_id, secret_key=secret_key)
            params["orderId"] = order_id
            payload = self._request_json(
                client=client,
                method="GET",
                url=f"{XFYUN_BASE_URL}/getResult",
                params=params,
                phase="result",
            )
            self._ensure_success(payload=payload, phase="result")
            content = payload.get("content")
            order_info = (
                content.get("orderInfo") if isinstance(content, dict) else None
            )
            if not isinstance(order_info, dict):
                raise ASRProviderError(
                    "XFYun ASR result response is missing order information"
                )

            try:
                status = int(order_info.get("status"))
            except (TypeError, ValueError) as exc:
                raise ASRProviderError(
                    "XFYun ASR result response has an invalid order status"
                ) from exc

            if status == 4:
                return self._extract_transcript(content.get("orderResult"))
            if status == -1:
                fail_type = order_info.get("failType")
                try:
                    fail_type_number = int(fail_type)
                except (TypeError, ValueError):
                    fail_type_number = 99
                reason = FAIL_TYPE_MESSAGES.get(
                    fail_type_number,
                    "unknown provider error",
                )
                raise ASRProviderError(
                    "XFYun ASR order failed "
                    f"(fail type {fail_type_number}: {reason})"
                )
            if status not in {0, 3}:
                raise ASRProviderError(
                    f"XFYun ASR returned unknown order status: {status}"
                )

            if query_number < MAX_RESULT_QUERIES - 1:
                self._sleep(POLL_INTERVAL_SECONDS)

        raise ASRProviderError("XFYun ASR result polling timed out")

    def _signed_params(self, *, app_id: str, secret_key: str) -> dict[str, str]:
        timestamp = str(int(self._now()))
        digest = hashlib.md5(
            f"{app_id}{timestamp}".encode("utf-8"),
            usedforsecurity=False,
        ).hexdigest()
        signature = base64.b64encode(
            hmac.new(
                secret_key.encode("utf-8"),
                digest.encode("utf-8"),
                hashlib.sha1,
            ).digest()
        ).decode("ascii")
        return {
            "appId": app_id,
            "ts": timestamp,
            "signa": signature,
        }

    @staticmethod
    def _file_chunks(media_file: Any) -> Iterator[bytes]:
        while chunk := media_file.read(UPLOAD_CHUNK_BYTES):
            yield chunk

    @staticmethod
    def _request_json(
        *,
        client: httpx.Client,
        method: str,
        url: str,
        params: dict[str, str],
        phase: str,
        headers: dict[str, str] | None = None,
        content: Iterator[bytes] | None = None,
    ) -> dict[str, Any]:
        try:
            response = client.request(
                method,
                url,
                params=params,
                headers=headers,
                content=content,
            )
            response.raise_for_status()
            payload = response.json()
        except httpx.HTTPError as exc:
            raise ASRProviderError(
                f"XFYun ASR {phase} request failed"
            ) from None
        except (ValueError, UnicodeDecodeError) as exc:
            raise ASRProviderError(
                f"XFYun ASR {phase} returned invalid JSON"
            ) from exc

        if not isinstance(payload, dict):
            raise ASRProviderError(
                f"XFYun ASR {phase} returned an invalid response"
            )
        return payload

    @staticmethod
    def _ensure_success(*, payload: dict[str, Any], phase: str) -> None:
        code = str(payload.get("code", ""))
        if code == "000000":
            return
        description = str(payload.get("descInfo", "provider error"))
        description = " ".join(description.split())[:200]
        raise ASRProviderError(
            f"XFYun ASR {phase} failed (code {code}: {description})"
        )

    @staticmethod
    def _extract_transcript(raw_order_result: object) -> str:
        if not isinstance(raw_order_result, str):
            raise ASRProviderError("XFYun ASR returned no transcription result")
        try:
            order_result = json.loads(raw_order_result)
            lattice = order_result["lattice"]
            words: list[str] = []
            for item in lattice:
                sentence = json.loads(item["json_1best"])
                for recognition in sentence["st"]["rt"]:
                    for word_segment in recognition["ws"]:
                        candidates = word_segment["cw"]
                        if candidates:
                            word = candidates[0].get("w")
                            if isinstance(word, str):
                                words.append(word)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ASRProviderError(
                "XFYun ASR returned an invalid transcription result"
            ) from exc

        transcript = "".join(words).strip()
        if not transcript:
            raise ASRProviderError("XFYun ASR returned an empty transcript")
        return transcript
