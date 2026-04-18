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

    runner = registry.get(preset)
    if runner is None or not runner.is_running:
        if not auto_start:
            raise RuntimeError(
                f"{preset.id} is not running. Call openhost.run({preset.id!r}) first, "
                f"or pass auto_start=True."
            )
        runner = registry.ensure_running(preset)

    effective_max = max_tokens if max_tokens is not None else preset.recommended_max_tokens

    return ChatOpenAI(
        base_url=runner.base_url,
        api_key="openhost",
        model=runner.upstream_model_id,  # llama.cpp/mlx advertise their own id
        streaming=streaming,
        max_tokens=effective_max,
        temperature=temperature,
        timeout=timeout,
        **kwargs,
    )
