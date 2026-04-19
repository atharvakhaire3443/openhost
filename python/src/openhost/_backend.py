"""Backend selection + command translation for llama.cpp.

Two possible runners for llama.cpp GGUF models:
  1. External ``llama-server`` binary on PATH (our default, fastest startup).
  2. Bundled ``python -m llama_cpp.server`` (the ``llama-cpp-python`` pip package
     — ships with the openhost install so new users don't need to install the
     C++ binary themselves).

The openhost preset stores a ``llama-server``-flavored command template; at
runtime we pick a backend and translate the flags accordingly.
"""
from __future__ import annotations

import importlib.util
import shutil
import sys
from dataclasses import dataclass


@dataclass
class BackendChoice:
    kind: str   # "llama-server" | "llama-cpp-python" | "mlx_lm.server"
    cmd_prefix: tuple[str, ...]
    flag_map: dict[str, str]   # llama-server flag → this backend's flag


# llama-server → llama-cpp-python server flag equivalents
_LLAMA_PY_FLAGMAP: dict[str, str] = {
    "-m": "--model",
    "-c": "--n_ctx",
    "--host": "--host",
    "--port": "--port",
    "-ngl": "--n_gpu_layers",
    "-fa": None,   # flash-attn is handled automatically by llama-cpp-python
    "--cache-type-k": "--cache_type_k",
    "--cache-type-v": "--cache_type_v",
    "--jinja": None,   # llama-cpp-python picks chat template from GGUF metadata
    "--alias": "--model_alias",
    "-md": None,       # draft model / speculative decoding not exposed by llama-cpp-python server
    "-ngld": None,
    "--draft-max": None,
    "--draft-min": None,
}

# Identity map — llama-server uses its own flags
_LLAMA_CPP_FLAGMAP: dict[str, str] = {}


def choose_llama_backend() -> BackendChoice:
    """Pick the best available llama.cpp runner for this machine."""
    if shutil.which("llama-server"):
        return BackendChoice(
            kind="llama-server",
            cmd_prefix=("llama-server",),
            flag_map=_LLAMA_CPP_FLAGMAP,
        )
    if importlib.util.find_spec("llama_cpp") is not None:
        return BackendChoice(
            kind="llama-cpp-python",
            cmd_prefix=(sys.executable, "-m", "llama_cpp.server"),
            flag_map=_LLAMA_PY_FLAGMAP,
        )
    raise RuntimeError(
        "No llama.cpp runtime available. Install one of:\n"
        "  pip install openhost               # bundles llama-cpp-python (all platforms)\n"
        "  brew install llama.cpp             # external binary on macOS\n"
        "  (Windows: download llama-server.exe from github.com/ggerganov/llama.cpp/releases)\n"
        "For NVIDIA GPU acceleration, see README for the CUDA install variant."
    )


def mlx_backend_available() -> bool:
    if shutil.which("mlx_lm.server"):
        return True
    return importlib.util.find_spec("mlx_lm") is not None


def translate_llama_command(
    template: list[str],
    backend: BackendChoice,
) -> list[str]:
    """Rewrite a llama-server command line to the active backend.

    - Replaces the leading ``llama-server`` with the backend's command prefix.
    - Translates each known flag. Drops flags that the backend doesn't support.
    - Leaves unknown flags as-is (with their values).
    """
    if not template:
        return []

    # Strip the `llama-server` leading token — we supply our own prefix.
    tokens = list(template)
    if tokens and tokens[0] == "llama-server":
        tokens = tokens[1:]

    # Identity for external llama-server path.
    if backend.kind == "llama-server":
        return list(backend.cmd_prefix) + tokens

    # Flag-by-flag translation.
    translated: list[str] = list(backend.cmd_prefix)
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in backend.flag_map:
            new_flag = backend.flag_map[tok]
            if new_flag is None:
                # Drop this flag. Some flags have a value that we also need to skip.
                if _flag_takes_value(tok) and i + 1 < len(tokens):
                    i += 2
                else:
                    i += 1
                continue
            translated.append(new_flag)
            if _flag_takes_value(tok) and i + 1 < len(tokens):
                translated.append(tokens[i + 1])
                i += 2
            else:
                i += 1
            continue
        # Unknown flag — pass through.
        translated.append(tok)
        i += 1
    return translated


def _flag_takes_value(flag: str) -> bool:
    """Best-effort — llama-server mostly uses whitespace-separated values."""
    valueless = {"--jinja"}
    return flag not in valueless


def llama_cpp_python_install_hint() -> str:
    """Return a hardware-aware install hint for llama-cpp-python upgrades."""
    try:
        from .hardware import detect
        hw = detect()
    except Exception:
        return "pip install openhost"
    if hw.nvidia_vram_gb > 0:
        return (
            "pip install --upgrade --force-reinstall llama-cpp-python "
            "--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124"
        )
    if hw.has_rocm:
        return (
            "pip install --upgrade --force-reinstall llama-cpp-python "
            "--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/rocm5.7"
        )
    if hw.has_metal:
        # Default llama-cpp-python wheel is already Metal-enabled on macOS arm64.
        return "pip install openhost   # Metal is already enabled on Apple Silicon"
    return "pip install openhost   # CPU baseline works"


def llama_cpp_python_has_gpu() -> bool:
    """Best-effort probe: is the installed llama-cpp-python built with GPU support?

    Returns False when llama_cpp isn't installed or when the probe fails.
    """
    try:
        from llama_cpp import llama_supports_gpu_offload  # type: ignore[attr-defined]
        return bool(llama_supports_gpu_offload())
    except Exception:
        return False


_WARNED_CPU_ONLY_ON_GPU_HW = False


def warn_if_gpu_unused(backend: BackendChoice) -> None:
    """Nudge users once if they have a GPU but the active backend is CPU-only."""
    global _WARNED_CPU_ONLY_ON_GPU_HW
    if _WARNED_CPU_ONLY_ON_GPU_HW:
        return
    if backend.kind != "llama-cpp-python":
        # External llama-server users are responsible for their own CUDA build.
        return

    try:
        from .hardware import detect
        hw = detect()
    except Exception:
        return

    if not (hw.nvidia_vram_gb > 0 or hw.has_rocm):
        return  # CPU-only hardware, nothing to nudge about

    if llama_cpp_python_has_gpu():
        return  # Installed wheel already has GPU support

    import sys
    gpu_kind = "NVIDIA" if hw.nvidia_vram_gb > 0 else "AMD ROCm"
    print(
        f"\n[openhost] Detected {gpu_kind} GPU but the installed llama-cpp-python is "
        f"CPU-only. Inference will be slow.\n"
        f"[openhost] For GPU acceleration run:\n"
        f"[openhost]   {llama_cpp_python_install_hint()}\n",
        file=sys.stderr,
        flush=True,
    )
    _WARNED_CPU_ONLY_ON_GPU_HW = True
