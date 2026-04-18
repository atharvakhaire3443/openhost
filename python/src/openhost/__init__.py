"""OpenHost — run local LLMs from Python, LangChain-compatible.

Quickstart:
    >>> import openhost
    >>> openhost.pull("qwen3.6-35b-mlx-turbo")
    >>> llm = openhost.make_chat("qwen3.6-35b-mlx-turbo", streaming=True)
    >>> for chunk in llm.stream("Hello"):
    ...     print(chunk.content, end="", flush=True)
"""
from __future__ import annotations

from typing import Union

from .presets import ModelPreset, list_presets, get_preset, register_preset, register_local_model
from .download import pull as _pull
from .runner import ModelRunner, RunnerInfo, RunnerError
from .registry import get_registry
from .chat import make_chat
from .search import (
    OpenHostSearchTool,
    SearchProvider,
    SearchResult,
    DuckDuckGoProvider,
    TavilyProvider,
    BraveProvider,
    SearXNGProvider,
)
from .transcription import (
    transcribe,
    make_default_transcriber,
    TranscriptResult,
    TranscriptSegment,
    TranscriptionError,
)
from .transcription.loader import OpenHostWhisper

__version__ = "0.2.0"


def pull(model_id: Union[str, ModelPreset], force: bool = False) -> str:
    """Download a model's weights to ~/.openhost/models/<id>/."""
    preset = model_id if isinstance(model_id, ModelPreset) else get_preset(model_id)
    if preset is None:
        raise ValueError(f"Unknown preset: {model_id!r}")
    return str(_pull(preset, force=force))


def run(model_id: Union[str, ModelPreset]) -> ModelRunner:
    """Start (or return the already-running) server for a model. Auto-pulls if needed."""
    return get_registry().ensure_running(model_id)


def stop(model_id: Union[str, ModelPreset]) -> None:
    get_registry().stop(model_id)


def stop_all() -> None:
    get_registry().stop_all()


def running() -> list[ModelRunner]:
    return get_registry().running()


__all__ = [
    # Presets
    "ModelPreset",
    "list_presets",
    "get_preset",
    "register_preset",
    "register_local_model",
    # Lifecycle
    "pull",
    "run",
    "stop",
    "stop_all",
    "running",
    "ModelRunner",
    "RunnerInfo",
    "RunnerError",
    # Chat
    "make_chat",
    # Search
    "OpenHostSearchTool",
    "SearchProvider",
    "SearchResult",
    "DuckDuckGoProvider",
    "TavilyProvider",
    "BraveProvider",
    "SearXNGProvider",
    # Transcription
    "transcribe",
    "make_default_transcriber",
    "TranscriptResult",
    "TranscriptSegment",
    "TranscriptionError",
    "OpenHostWhisper",
]
