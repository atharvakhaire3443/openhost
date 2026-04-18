"""Auto-register a ``ModelPreset`` from a HuggingFace repo id.

Turns ``owner/repo`` (optionally ``owner/repo:QUANT``) into a usable preset
by inspecting the repo file list on HF and picking sensible defaults:

  - GGUF repo → ``llama.cpp`` backend, auto-pick a quant (default Q4_K_M).
  - ``config.json`` + safetensors repo → ``mlx-lm`` backend on Apple Silicon.

Example:
    from openhost import from_hf, make_chat
    from_hf("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")  # picks Q4_K_M
    llm = make_chat("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")
"""
from __future__ import annotations

import re
from typing import Optional

from .presets import (
    ModelPreset,
    register_preset,
    get_preset,
    _LLAMA_CMD,
    _MLX_CMD,
)


# Ordered preference for automatic quant selection when the user doesn't pick one.
_QUANT_PREF = [
    "Q4_K_M",   # best ratio for 7-13B
    "Q5_K_M",
    "Q4_K_S",
    "Q5_0",
    "Q8_0",
    "Q6_K",
    "Q3_K_M",
    "IQ4_XS",
    "F16",
    "BF16",
]

_QUANT_RE = re.compile(
    r"-(?P<q>Q\d[_A-Z0-9]*|IQ\d[_A-Z0-9]*|BF16|F16|FP16|FP32)(?:-\d{5}-of-\d{5})?\.gguf$",
    re.IGNORECASE,
)


def parse_model_ref(ref: str) -> tuple[str, Optional[str]]:
    """Split ``owner/repo:QUANT`` into ``(repo, quant_or_None)``."""
    if ":" in ref and "/" in ref.split(":", 1)[0]:
        repo, quant = ref.split(":", 1)
        return repo, quant or None
    return ref, None


def is_hf_ref(ref: str) -> bool:
    """Heuristic: HF repos contain '/' and aren't local paths."""
    if "/" not in ref:
        return False
    if ref.startswith(("/", "~", "./", "../")):
        return False
    return True


def preset_id_for(repo: str, quant: Optional[str] = None) -> str:
    """Deterministic, filesystem-safe id for an auto-registered preset."""
    base = repo.replace("/", "--")
    if quant:
        base += f"-{quant}"
    return base


def from_hf(
    repo: str,
    *,
    quant: Optional[str] = None,
    backend: Optional[str] = None,
    context_length: int = 32768,
    filename: Optional[str] = None,
    display_name: Optional[str] = None,
) -> ModelPreset:
    # Allow callers to pass `"owner/repo:QUANT"` directly.
    if quant is None:
        repo, parsed_quant = parse_model_ref(repo)
        if parsed_quant:
            quant = parsed_quant
    """Inspect a HF repo, auto-detect backend, and register a preset for it.

    Returns the (possibly cached) preset. Idempotent: calling twice with the
    same ``(repo, quant)`` returns the same preset without re-querying HF.

    Args:
        repo: HuggingFace repo id, e.g. ``"bartowski/Meta-Llama-3.1-8B-Instruct-GGUF"``.
        quant: quant tag (``Q4_K_M``, ``Q5_K_M`` …) to prefer for GGUF repos.
        backend: override auto-detection (``"llama.cpp"`` or ``"mlx-lm"``).
        context_length: set the -c argument for llama-server. Default 32k.
        filename: exact GGUF filename to use; overrides quant preference.
    """
    cache_id = preset_id_for(repo, quant=quant)
    cached = get_preset(cache_id)
    if cached:
        return cached

    files = _list_hf_files(repo)

    gguf_files = [f for f in files if f.endswith(".gguf") and not _looks_like_mmproj(f)]
    mmproj_files = [f for f in files if _looks_like_mmproj(f)]
    has_config = "config.json" in files
    has_safetensors = any(f.endswith(".safetensors") for f in files)
    # The real weights filename pattern for mlx-lm repos
    has_mlx_weights = any(f.startswith("model-") and f.endswith(".safetensors") for f in files) \
                       or "model.safetensors" in files

    chosen_backend = backend or _detect_backend(
        gguf_files=gguf_files,
        has_config=has_config,
        has_safetensors=has_safetensors,
        has_mlx_weights=has_mlx_weights,
        repo=repo,
    )

    if chosen_backend == "llama.cpp":
        shard_siblings: list[str] = []
        if filename:
            primary = filename
            # If the user named a sharded file, still collect siblings so pull() gets them all.
            if _SHARD_RE.search(filename):
                base = _SHARD_RE.sub("", filename)
                shard_siblings = sorted(
                    f for f in gguf_files
                    if f != filename and f.startswith(base) and _SHARD_RE.search(f)
                )
        else:
            primary, shard_siblings = _pick_gguf(gguf_files, user_quant=quant)
        if not primary:
            raise ValueError(
                f"{repo!r}: no usable GGUF file found. "
                f"Available: {', '.join(gguf_files[:5])}{'...' if len(gguf_files) > 5 else ''}"
            )
        detected_quant = quant or _extract_quant_from_filename(primary) or "?"
        preset = ModelPreset(
            id=preset_id_for(repo, quant=detected_quant if quant or detected_quant != "?" else None),
            display_name=display_name or f"{repo} ({detected_quant})",
            backend="llama.cpp",
            hf_repo=repo,
            primary_file=primary,
            extra_files=tuple(shard_siblings) + tuple(mmproj_files[:1]),
            command_template=_LLAMA_CMD,
            context_length=context_length,
            family=_guess_family(repo),
        )
    elif chosen_backend == "mlx-lm":
        preset = ModelPreset(
            id=cache_id,
            display_name=display_name or f"{repo} (MLX)",
            backend="mlx-lm",
            hf_repo=repo,
            command_template=_MLX_CMD,
            context_length=context_length,
            family=_guess_family(repo),
        )
    else:
        raise ValueError(f"Unsupported backend: {chosen_backend!r}")

    register_preset(preset)
    return preset


# ----- helpers ------------------------------------------------------------


def _list_hf_files(repo: str) -> list[str]:
    try:
        from huggingface_hub import HfApi
    except ImportError as exc:
        raise ImportError(
            "huggingface_hub is required for auto-detection. "
            "Install with: pip install huggingface_hub"
        ) from exc
    try:
        api = HfApi()
        return list(api.list_repo_files(repo))
    except Exception as exc:  # noqa: BLE001
        raise ValueError(
            f"Could not list files for HuggingFace repo {repo!r}. "
            f"Does it exist and is it public? Underlying error: {exc}"
        ) from exc


def _detect_backend(
    *,
    gguf_files: list[str],
    has_config: bool,
    has_safetensors: bool,
    has_mlx_weights: bool,
    repo: str,
) -> str:
    if gguf_files:
        return "llama.cpp"
    # mlx-community/* or MLX-quantized repos usually carry config.json + safetensors
    if has_config and (has_mlx_weights or "mlx" in repo.lower()):
        return "mlx-lm"
    if has_config and has_safetensors:
        return "mlx-lm"  # best-effort; user can override with backend="..."
    raise ValueError(
        f"Could not auto-detect backend for {repo!r}. "
        f"No GGUF files, no config.json+safetensors. "
        f"Pass backend='llama.cpp' or 'mlx-lm' explicitly, or use register_preset(...)."
    )


def _looks_like_mmproj(filename: str) -> bool:
    name = filename.lower()
    return "mmproj" in name and name.endswith(".gguf")


_SHARD_RE = re.compile(r"-\d{5}-of-\d{5}\.gguf$", re.IGNORECASE)
_SHARD1_RE = re.compile(r"-00001-of-\d{5}\.gguf$", re.IGNORECASE)


def _pick_gguf(files: list[str], user_quant: Optional[str]) -> tuple[Optional[str], list[str]]:
    """Return (primary_file, shard_siblings).

    llama-server auto-loads sibling shards when pointed at the first shard; we
    just need to download all of them, so shard filenames go into extra_files.
    """
    if not files:
        return None, []

    def _matches(filename: str, quant: str) -> bool:
        low = filename.lower()
        q = quant.lower()
        return f"-{q}." in low or f"-{q}-" in low or f".{q}." in low

    def _resolve(quant: str) -> Optional[str]:
        # Shard-1 wins over any other shard of the same quant; non-sharded wins
        # over shard-1.
        non_shard = [f for f in files if _matches(f, quant) and not _SHARD_RE.search(f)]
        if non_shard:
            return non_shard[0]
        shard1 = [f for f in files if _matches(f, quant) and _SHARD1_RE.search(f)]
        if shard1:
            return shard1[0]
        return None

    chosen: Optional[str] = None
    if user_quant:
        chosen = _resolve(user_quant)
    if not chosen:
        for quant in _QUANT_PREF:
            chosen = _resolve(quant)
            if chosen:
                break
    if not chosen:
        # Fall back to first non-sharded file, or just the first file.
        non_shard = [f for f in files if not _SHARD_RE.search(f)]
        chosen = non_shard[0] if non_shard else files[0]

    # Collect sibling shards of the chosen file.
    siblings: list[str] = []
    if _SHARD_RE.search(chosen):
        base = _SHARD_RE.sub("", chosen)
        siblings = sorted(
            f for f in files
            if f != chosen and f.startswith(base) and _SHARD_RE.search(f)
        )
    return chosen, siblings


def _extract_quant_from_filename(filename: str) -> Optional[str]:
    m = _QUANT_RE.search(filename)
    if m:
        return m.group("q").upper()
    return None


def _guess_family(repo: str) -> str:
    low = repo.lower()
    if "qwen" in low:
        return "qwen"
    if "llama" in low:
        return "llama"
    if "mistral" in low:
        return "mistral"
    if "gemma" in low:
        return "gemma"
    if "phi" in low:
        return "phi"
    if "deepseek" in low:
        return "deepseek"
    return "general"
