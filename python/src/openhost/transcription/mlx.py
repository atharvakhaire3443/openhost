"""MLX-whisper backend (Apple Silicon)."""
from __future__ import annotations

import time

from .base import TranscriptResult, TranscriptSegment, TranscriptionError


class MLXWhisperBackend:
    name = "mlx-whisper"

    def __init__(self, model: str = "mlx-community/whisper-large-v3-turbo") -> None:
        self.model = model

    def transcribe(self, audio_path: str) -> TranscriptResult:
        try:
            import mlx_whisper
        except ImportError as exc:
            raise TranscriptionError(
                "mlx-whisper not installed. Install with: pip install 'openhost[whisper-mlx]'"
            ) from exc

        started = time.time()
        try:
            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=self.model,
                word_timestamps=False,
            )
        except Exception as exc:
            raise TranscriptionError(f"mlx-whisper transcription failed: {exc}") from exc
        elapsed = time.time() - started

        segments = [
            TranscriptSegment(
                start=float(s.get("start", 0.0)),
                end=float(s.get("end", 0.0)),
                text=(s.get("text", "") or "").strip(),
            )
            for s in result.get("segments", [])
        ]
        return TranscriptResult(
            text=(result.get("text", "") or "").strip(),
            segments=segments,
            language=result.get("language"),
            duration_sec=elapsed,
            model=self.model,
        )
