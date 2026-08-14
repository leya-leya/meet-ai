from abc import ABC, abstractmethod


class ASRProvider(ABC):
    @abstractmethod
    def transcribe(self, file_path: str) -> str:
        """Transcribe a local media file to plain text."""
