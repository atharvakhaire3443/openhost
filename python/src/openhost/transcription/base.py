"""Shared transcription types."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


class TranscriptionError(RuntimeError):
    pass


@dataclass
class TranscriptSegment:
    start: float  # seconds
    end: float
    text: str


@dataclass
class TranscriptResult:
    text: str
    segments: list[TranscriptSegment] = field(default_factory=list)
    language: str | None = None
    duration_sec: float = 0.0
    model: str = ""


class Transcriber(Protocol):
    """Backend interface: take a path to an audio file, return text + segments."""

    name: str

    def transcribe(self, audio_path: str) -> TranscriptResult: ...
