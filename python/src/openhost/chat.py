"""LangChain ChatOpenAI factory wired to a locally-managed model."""
from __future__ import annotations

from typing import Any

from .presets import ModelPreset
from .registry import get_registry


def make_chat(
    model: "str | ModelPreset",
    *,
    streaming: bool = False,
    max_tokens: int | None = None,
    temperature: float = 0.7,
    timeout: float = 600,
    auto_start: bool = True,
    speculate_with: "str | ModelPreset | None" = None,
    profile: "str | None" = None,
    warmup: bool = False,
    **kwargs: Any,
):
    """Return a preconfigured `ChatOpenAI` for a local model.

    Auto-starts the model if needed. User never deals with ports.

    Example:
        >>> import openhost
        >>> llm = openhost.make_chat("qwen3.6-35b-mlx-turbo", streaming=True)
        >>> for chunk in llm.stream("Hello"):
        ...     print(chunk.content, end="", flush=True)
    """
    try:
        from langchain_openai import ChatOpenAI
    except ImportError as exc:
        raise ImportError(
            "make_chat requires langchain-openai. Install with: pip install langchain-openai"
        ) from exc

    registry = get_registry()
    preset = registry.resolve(model)

    draft_path: "str | None" = None
    if speculate_with is not None:
        from . import paths
        from .download import pull as _pull
        draft_preset = registry.resolve(speculate_with)
        if draft_preset.backend != "llama.cpp":
            raise RuntimeError(
                f"speculate_with draft must be a llama.cpp-backed preset; got "
                f"{draft_preset.backend!r}."
            )
        # Ensure draft weights are present, then point the runner at the GGUF file.
        _pull(draft_preset)
        draft_dir = paths.effective_model_dir(draft_preset)
        if draft_preset.primary_file:
            draft_path = str(draft_dir / draft_preset.primary_file)
        else:
            raise RuntimeError(
                f"speculate_with draft {draft_preset.id!r} has no primary_file set."
            )

    runner = registry.get(preset)
    if runner is None or not runner.is_running:
        if not auto_start:
            raise RuntimeError(
                f"{preset.id} is not running. Call openhost.run({preset.id!r}) first, "
                f"or pass auto_start=True."
            )
        runner = registry.ensure_running(
            preset,
            draft_model_path=draft_path,
            profile=profile,
            warmup=warmup,
        )

    effective_max = max_tokens if max_tokens is not None else preset.recommended_max_tokens

    # Custom httpx client: rewrites Qwen's non-standard `reasoning` field into
    # standard `content` on the way back, so the OpenAI SDK / langchain don't
    # see empty messages when the model thinks.
    from ._qwen_compat import build_http_client
    http_client = kwargs.pop("http_client", None) or build_http_client(timeout=timeout)

    return ChatOpenAI(
        base_url=runner.base_url,
        api_key="openhost",
        model=runner.upstream_model_id,  # llama.cpp/mlx advertise their own id
        streaming=streaming,
        max_tokens=effective_max,
        temperature=temperature,
        timeout=timeout,
        http_client=http_client,
        **kwargs,
    )
