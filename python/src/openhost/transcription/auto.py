"""Auto-select the best available whisper backend for the current machine."""
from __future__ import annotations

import importlib
import platform
from typing import Optional

from .base import Transcriber, TranscriptResult, TranscriptionError


def _has(mod: str) -> bool:
    try:
        importlib.import_module(mod)
        return True
    except ImportError:
        return False


def make_default_transcriber() -> Transcriber:
    """Pick mlx-whisper on Apple Silicon if available, else faster-whisper.

    On Windows / Linux we skip the MLX probe entirely — mlx-whisper is Apple-only.
    """
    is_apple_silicon = platform.system() == "Darwin" and platform.machine() == "arm64"

    if is_apple_silicon and _has("mlx_whisper"):
        from .mlx import MLXWhisperBackend
        return MLXWhisperBackend()

    if _has("faster_whisper"):
        from .faster import FasterWhisperBackend
        return FasterWhisperBackend()

    hint = (
        "  pip install 'openhost[whisper-faster]'   # Windows / Linux / CPU or CUDA"
        if not is_apple_silicon
        else "  pip install 'openhost[whisper-mlx]'      # Apple Silicon\n"
             "  pip install 'openhost[whisper-faster]'   # CPU / CUDA fallback"
    )
    raise TranscriptionError("No whisper backend available. Install one of:\n" + hint)


def transcribe(
    audio_path: str,
    *,
    backend: Optional[Transcriber] = None,
) -> TranscriptResult:
    """One-shot transcription. Uses auto-detected backend unless overridden."""
    transcriber = backend or make_default_transcriber()
    return transcriber.transcribe(audio_path)
