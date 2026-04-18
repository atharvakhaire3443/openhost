"""Canonical directories for OpenHost state + models."""
from __future__ import annotations

import os
from pathlib import Path


def openhost_home() -> Path:
    env = os.environ.get("OPENHOST_HOME")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".openhost"


def models_root() -> Path:
    return openhost_home() / "models"


def model_dir(preset_id: str) -> Path:
    return models_root() / preset_id


def effective_model_dir(preset) -> Path:
    """Return the directory that should be treated as the model root for a preset."""
    if getattr(preset, "local_path", None):
        return Path(preset.local_path).expanduser()
    return model_dir(preset.id)


def ensure_dirs() -> None:
    models_root().mkdir(parents=True, exist_ok=True)
