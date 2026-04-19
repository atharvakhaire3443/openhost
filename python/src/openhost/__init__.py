"""OpenHost — run local LLMs from Python, LangChain-compatible.

Quickstart:
    >>> import openhost
    >>> openhost.pull("qwen3-8b-gguf")
    >>> llm = openhost.make_chat("qwen3-8b-gguf", streaming=True)
    >>> for chunk in llm.stream("Hello"):
    ...     print(chunk.content, end="", flush=True)

Advanced primitives (0.3.0):
    openhost.panel(...)             # parallel multi-model ensemble + judge
    openhost.extract(...)            # pydantic-validated structured output
    openhost.session(...)            # persistent, branchable conversations
    openhost.memory(...)             # Graphiti-style temporal KG memory
    openhost.voice_chat(...)         # mic → whisper → LLM loop
    openhost.make_chat(..., speculate_with=...)   # llama.cpp spec. decoding
"""
from __future__ import annotations

from typing import Union

from .presets import (
    ModelPreset,
    list_presets,
    get_preset,
    register_preset,
    register_local_model,
)
from .hf_auto import from_hf
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

# 0.3.0 primitives
from .panel import panel, PanelResult
from .extract import extract, ExtractionError
from .session import session, ChatSession, Turn, Branch
from .memory import memory, Memory, Fact

__version__ = "0.4.0"


def pull(model_id: Union[str, ModelPreset], force: bool = False) -> str:
    """Download a model's weights to ~/.openhost/models/<id>/.

    Accepts either a built-in preset id, a previously-registered preset name,
    or a HuggingFace repo string like ``"owner/name"`` (auto-detects backend).
    Append ``:QUANT`` (e.g. ``"owner/name:Q5_K_M"``) to pick a specific GGUF.
    """
    if isinstance(model_id, ModelPreset):
        preset = model_id
    else:
        preset = get_preset(model_id)
        if preset is None:
            from .hf_auto import is_hf_ref, parse_model_ref, from_hf
            if is_hf_ref(model_id):
                repo, quant = parse_model_ref(model_id)
                preset = from_hf(repo, quant=quant)
            else:
                raise ValueError(f"Unknown preset: {model_id!r}")
    return str(_pull(preset, force=force))


def run(
    model_id: Union[str, ModelPreset],
    *,
    profile: "str | None" = None,
    warmup: bool = False,
) -> ModelRunner:
    """Start (or return the already-running) server for a model. Auto-pulls if needed.

    Args:
        profile: one of ``"fast"``, ``"quality"``, ``"lowmem"``, ``"balanced"``.
            Selects a bundle of llama.cpp tuning knobs. See :mod:`openhost.profiles`.
        warmup: if True, issue a 1-token request after startup so the first
            real call doesn't pay cold-cache cost.
    """
    return get_registry().ensure_running(model_id, profile=profile, warmup=warmup)


def check_setup() -> None:
    """Print a diagnostic: what hardware openhost sees, which llama backend is
    active, and whether GPU acceleration is enabled. Use before the first
    ``run()`` on a new machine to verify the install is ready."""
    from .hardware import detect
    from ._backend import (
        choose_llama_backend,
        llama_cpp_python_has_gpu,
        llama_cpp_python_install_hint,
        mlx_backend_available,
    )

    hw = detect()
    print(f"openhost {__version__}")
    print(f"Hardware: {hw.describe()}")

    try:
        backend = choose_llama_backend()
        print(f"llama.cpp backend: {backend.kind}")
        if backend.kind == "llama-cpp-python":
            gpu = llama_cpp_python_has_gpu()
            print(f"  GPU-enabled wheel: {gpu}")
            if (hw.nvidia_vram_gb > 0 or hw.has_rocm) and not gpu:
                print("  ⚠  Your GPU will be unused until you reinstall with a GPU wheel:")
                print(f"    {llama_cpp_python_install_hint()}")
    except Exception as exc:
        print(f"llama.cpp backend: NOT AVAILABLE — {exc}")

    print(f"MLX backend available: {mlx_backend_available()}")


def stop(model_id: Union[str, ModelPreset]) -> None:
    get_registry().stop(model_id)


def stop_all() -> None:
    get_registry().stop_all()


def running() -> list[ModelRunner]:
    return get_registry().running()


def voice_chat(*args, **kwargs):
    """Open a mic → whisper → LLM loop. Requires ``openhost[voice]``."""
    from .voice import voice_chat as _vc
    return _vc(*args, **kwargs)


__all__ = [
    # Presets
    "ModelPreset",
    "list_presets",
    "get_preset",
    "register_preset",
    "register_local_model",
    "from_hf",
    # Lifecycle
    "pull",
    "run",
    "stop",
    "stop_all",
    "running",
    "check_setup",
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
    # 0.3.0 primitives
    "panel",
    "PanelResult",
    "extract",
    "ExtractionError",
    "session",
    "ChatSession",
    "Turn",
    "Branch",
    "memory",
    "Memory",
    "Fact",
    "voice_chat",
]
