"""LangChain-style document loader wrapping whisper transcription."""
from __future__ import annotations

from typing import Iterable, Optional

from .auto import make_default_transcriber
from .base import Transcriber


class OpenHostWhisper:
    """Return LangChain `Document`s from an audio file.

    In `verbose=True` mode, each segment is its own Document with `start`/`end`
    metadata — ideal for chunking a meeting into retrievable snippets for RAG.
    """

    def __init__(
        self,
        audio_path: str,
        *,
        verbose: bool = False,
        backend: Optional[Transcriber] = None,
    ) -> None:
        self.audio_path = audio_path
        self.verbose = verbose
        self.backend = backend or make_default_transcriber()

    def load(self) -> list:
        try:
            from langchain_core.documents import Document
        except ImportError as exc:
            raise ImportError(
                "OpenHostWhisper requires langchain-core. "
                "Install with: pip install langchain-core"
            ) from exc

        result = self.backend.transcribe(self.audio_path)
        if self.verbose and result.segments:
            return [
                Document(
                    page_content=seg.text,
                    metadata={
                        "source": self.audio_path,
                        "start": seg.start,
                        "end": seg.end,
                        "language": result.language,
                    },
                )
                for seg in result.segments
            ]
        return [
            Document(
                page_content=result.text,
                metadata={"source": self.audio_path, "language": result.language},
            )
        ]

    def lazy_load(self) -> Iterable:
        yield from self.load()
