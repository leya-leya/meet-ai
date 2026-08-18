import os
from pathlib import Path

from dotenv import load_dotenv

from app.providers.llm.base import LLMProvider, LLMProviderError
from app.providers.llm.mock import MockLLMProvider
from app.providers.llm.real import RealLLMProvider


PROJECT_ROOT = Path(__file__).resolve().parents[4]


def get_llm_provider() -> LLMProvider:
    load_dotenv(PROJECT_ROOT / ".env", override=False)
    provider_name = os.getenv("LLM_PROVIDER", "mock").strip().lower() or "mock"
    if provider_name == "mock":
        return MockLLMProvider()
    if provider_name == "deepseek":
        return RealLLMProvider()
    raise LLMProviderError(f"Unsupported LLM provider: {provider_name}")
