from abc import ABC, abstractmethod


class LLMProviderError(RuntimeError):
    """A safe, user-readable error raised by an LLM provider."""


class LLMProvider(ABC):
    @abstractmethod
    def summarize(self, transcript: str) -> str:
        """Summarize a transcript as Markdown."""
