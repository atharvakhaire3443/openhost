"""Transcription backends + a simple `transcribe()` helper.

Backends are plug-in:
  - MLXWhisperBackend  → Apple Silicon (fast, Neural Engine). Requires `mlx-whisper`.
  - FasterWhisperBackend → cross-platform (CPU/CUDA). Requires `faster-whisper`.

Pick a backend per platform. The `transcribe()` free function auto-picks one.
"""
from .base import Transcriber, TranscriptResult, TranscriptSegment, TranscriptionError
from .auto import transcribe, make_default_transcriber

__all__ = [
    "Transcriber",
    "TranscriptResult",
    "TranscriptSegment",
    "TranscriptionError",
    "transcribe",
    "make_default_transcriber",
]

# Backends are imported lazily in auto.py so unused backends don't impose their
# deps. Power users can import them directly:
#   from openhost.transcription.mlx import MLXWhisperBackend
#   from openhost.transcription.faster import FasterWhisperBackend
