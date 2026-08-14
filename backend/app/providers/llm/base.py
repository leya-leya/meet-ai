from abc import ABC, abstractmethod


class LLMProvider(ABC):
    @abstractmethod
    def summarize(self, transcript: str) -> str:
        """Summarize a transcript as Markdown."""
