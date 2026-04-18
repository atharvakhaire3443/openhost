"""faster-whisper backend (CPU / CUDA)."""
from __future__ import annotations

import time
from typing import Optional

from .base import TranscriptResult, TranscriptSegment, TranscriptionError


class FasterWhisperBackend:
    name = "faster-whisper"

    def __init__(
        self,
        model: str = "large-v3-turbo",
        device: str = "auto",
        compute_type: Optional[str] = None,
    ) -> None:
        self.model = model
        self.device = device
        self.compute_type = compute_type

    def transcribe(self, audio_path: str) -> TranscriptResult:
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise TranscriptionError(
                "faster-whisper not installed. "
                "Install with: pip install 'openhost[whisper-faster]'"
            ) from exc

        started = time.time()
        compute_type = self.compute_type or ("float16" if self.device != "cpu" else "int8")
        try:
            model = WhisperModel(self.model, device=self.device, compute_type=compute_type)
            segments_iter, info = model.transcribe(audio_path)
            segs = []
            texts = []
            for s in segments_iter:
                segs.append(TranscriptSegment(start=s.start, end=s.end, text=s.text.strip()))
                texts.append(s.text.strip())
        except Exception as exc:
            raise TranscriptionError(f"faster-whisper transcription failed: {exc}") from exc
        elapsed = time.time() - started

        return TranscriptResult(
            text=" ".join(texts).strip(),
            segments=segs,
            language=getattr(info, "language", None),
            duration_sec=elapsed,
            model=self.model,
        )
