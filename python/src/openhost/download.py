"""Model download via huggingface_hub."""
from __future__ import annotations

from pathlib import Path

from . import paths
from .presets import ModelPreset


class DownloadError(RuntimeError):
    pass


def is_present(preset: ModelPreset) -> bool:
    """True if weights are already on disk (including user-specified local paths)."""
    directory = paths.effective_model_dir(preset)
    if not directory.exists():
        return False
    if preset.backend == "llama.cpp":
        if preset.primary_file and not (directory / preset.primary_file).exists():
            return False
        return True
    if preset.backend == "mlx-lm":
        return (directory / "config.json").exists() and any(directory.glob("*.safetensors"))
    return False


def pull(
    preset: ModelPreset,
    force: bool = False,
    progress: bool = True,
) -> Path:
    """Download a preset's weights to ~/.openhost/models/<id>/ and return the directory.

    Skips download if already present unless `force=True`. If the preset has a
    `local_path` set, no download happens — we just validate.
    """
    if preset.local_path:
        target = Path(preset.local_path).expanduser()
        if not is_present(preset):
            raise DownloadError(
                f"local_path {target} does not contain the expected files for {preset.id}."
            )
        return target

    paths.ensure_dirs()
    target = paths.model_dir(preset.id)

    if not force and is_present(preset):
        return target

    if not preset.hf_repo:
        raise DownloadError(
            f"Preset {preset.id!r} has no hf_repo and no local_path — nothing to pull."
        )

    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:
        raise DownloadError(
            "huggingface_hub is required. Install with: pip install huggingface_hub"
        ) from exc

    allow_patterns = _build_allow_patterns(preset)
    snapshot_download(
        repo_id=preset.hf_repo,
        local_dir=str(target),
        allow_patterns=allow_patterns,
        max_workers=4,
    )
    if not is_present(preset):
        raise DownloadError(
            f"Download of {preset.id} completed but expected files are missing. "
            f"Check {target}."
        )
    return target


def _build_allow_patterns(preset: ModelPreset) -> list[str] | None:
    """Return HuggingFace allow patterns. None = all files."""
    if preset.backend == "llama.cpp":
        patterns: list[str] = []
        if preset.primary_file:
            patterns.append(preset.primary_file)
        patterns.extend(preset.extra_files)
        patterns.append("*.json")   # tokenizer/config maybe
        patterns.append("README*")
        return patterns
    if preset.backend == "mlx-lm":
        # Full repo: config, tokenizer, weights
        return None
    return None
