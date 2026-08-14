from pathlib import Path

from app.providers.asr.base import ASRProvider


MOCK_TRANSCRIPT = "这是一段用于自动化测试的转写文本。"


class MockASRProvider(ASRProvider):
    def transcribe(self, file_path: str) -> str:
        if not Path(file_path).is_file():
            raise FileNotFoundError(f"Media file not found: {file_path}")
        return MOCK_TRANSCRIPT
