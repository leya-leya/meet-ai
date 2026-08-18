from abc import ABC, abstractmethod


class ASRProviderError(RuntimeError):
    """A safe, user-readable error raised by an ASR provider."""


class ASRProvider(ABC):
    @abstractmethod
    def transcribe(self, file_path: str) -> str:
        """Transcribe a local media file to plain text."""
