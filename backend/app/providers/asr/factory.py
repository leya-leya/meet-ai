import os
from pathlib import Path

from dotenv import load_dotenv

from app.providers.asr.base import ASRProvider, ASRProviderError
from app.providers.asr.mock import MockASRProvider
from app.providers.asr.real import RealASRProvider


PROJECT_ROOT = Path(__file__).resolve().parents[4]


def get_asr_provider() -> ASRProvider:
    load_dotenv(PROJECT_ROOT / ".env", override=False)
    provider_name = os.getenv("ASR_PROVIDER", "mock").strip().lower() or "mock"
    if provider_name == "mock":
        return MockASRProvider()
    if provider_name == "xfyun":
        return RealASRProvider()
    raise ASRProviderError(f"Unsupported ASR provider: {provider_name}")
