"""Built-in model presets. Each preset is a self-contained recipe for pulling
and running a model. Users can extend via `openhost.register(...)`."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


Backend = Literal["llama.cpp", "mlx-lm"]


@dataclass(frozen=True)
class ModelPreset:
    id: str
    display_name: str
    backend: Backend
    hf_repo: str = ""                            # empty if `local_path` is set
    # For GGUF: one file that is the actual weights. For MLX: all repo files.
    primary_file: str | None = None
    extra_files: tuple[str, ...] = ()            # allow list (glob ok) of extra files to fetch
    command_template: tuple[str, ...] = ()       # templated with {path}, {port}, {primary_file}
    context_length: int = 32768
    approx_size_gb: float = 1.0
    recommended_max_tokens: int = 4096
    family: str = "general"
    # If set, skip any download and treat this directory as the ready-to-use model dir.
    local_path: str | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "display_name": self.display_name,
            "backend": self.backend,
            "hf_repo": self.hf_repo,
            "primary_file": self.primary_file,
            "context_length": self.context_length,
            "approx_size_gb": self.approx_size_gb,
            "family": self.family,
            "local_path": self.local_path,
        }


# Cross-platform llama.cpp command: reads one GGUF + optional mmproj
_LLAMA_CMD: tuple[str, ...] = (
    "llama-server",
    "-m", "{path}/{primary_file}",
    "-c", "{context_length}",
    "--host", "127.0.0.1",
    "--port", "{port}",
    "--jinja",
    "-ngl", "99",
    "-fa", "on",
    "--cache-type-k", "q8_0",
    "--cache-type-v", "q8_0",
    "--alias", "{id}",
)

# MLX (Apple Silicon only) — takes model directory
_MLX_CMD: tuple[str, ...] = (
    "mlx_lm.server",
    "--model", "{path}",
    "--host", "127.0.0.1",
    "--port", "{port}",
)


_PRESETS: dict[str, ModelPreset] = {
    "qwen3.6-35b-mlx-turbo": ModelPreset(
        id="qwen3.6-35b-mlx-turbo",
        display_name="Qwen3.6 35B MoE (MLX 4-bit DWQ)",
        backend="mlx-lm",
        hf_repo="mlx-community/Qwen3.6-35B-A3B-4bit-DWQ",
        command_template=_MLX_CMD,
        context_length=32768,
        approx_size_gb=20.0,
        recommended_max_tokens=4096,
        family="qwen",
    ),
    "qwen3.5-35b-uncensored": ModelPreset(
        id="qwen3.5-35b-uncensored",
        display_name="Qwen3.5 35B MoE Uncensored (GGUF Q6_K)",
        backend="llama.cpp",
        hf_repo="bartowski/Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive-GGUF",
        primary_file="Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive-Q6_K.gguf",
        extra_files=("mmproj-*.gguf",),
        command_template=_LLAMA_CMD,
        context_length=65536,
        approx_size_gb=30.0,
        recommended_max_tokens=4096,
        family="qwen",
    ),
    "qwen3-8b-gguf": ModelPreset(
        id="qwen3-8b-gguf",
        display_name="Qwen3 8B (GGUF Q4_K_M)",
        backend="llama.cpp",
        hf_repo="Qwen/Qwen3-8B-GGUF",
        primary_file="Qwen3-8B-Q4_K_M.gguf",
        command_template=_LLAMA_CMD,
        context_length=32768,
        approx_size_gb=4.8,
        recommended_max_tokens=4096,
        family="qwen",
    ),
}


def list_presets() -> list[ModelPreset]:
    return list(_PRESETS.values())


def get_preset(preset_id: str) -> ModelPreset | None:
    return _PRESETS.get(preset_id)


def register_preset(preset: ModelPreset) -> None:
    _PRESETS[preset.id] = preset


def register_local_model(
    id: str,
    backend: Backend,
    path: str,
    *,
    primary_file: str | None = None,
    display_name: str | None = None,
    context_length: int = 32768,
    command_template: tuple[str, ...] | None = None,
    extra_args: tuple[str, ...] = (),
) -> ModelPreset:
    """Register an already-downloaded model that lives on disk.

    Examples:
        # MLX model you've downloaded yourself
        register_local_model(
            "my-qwen3.6", "mlx-lm",
            "~/models/qwen3.6-35b-mlx",
        )

        # GGUF sitting in ~/models/
        register_local_model(
            "my-qwen3.5", "llama.cpp",
            "~/models/qwen3.5-35b-uncensored",
            primary_file="Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive-Q6_K.gguf",
        )
    """
    cmd = command_template or (_LLAMA_CMD if backend == "llama.cpp" else _MLX_CMD)
    preset = ModelPreset(
        id=id,
        display_name=display_name or id,
        backend=backend,
        hf_repo="",
        primary_file=primary_file,
        command_template=tuple(cmd) + tuple(extra_args),
        context_length=context_length,
        local_path=path,
    )
    register_preset(preset)
    return preset
