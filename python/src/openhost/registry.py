"""Runtime registry of running model runners. One process, one registry."""
from __future__ import annotations

import atexit
import threading
from typing import Optional

from .presets import ModelPreset, get_preset
from .runner import ModelRunner, RunnerError


class _Registry:
    def __init__(self) -> None:
        self._runners: dict[str, ModelRunner] = {}
        self._lock = threading.Lock()
        atexit.register(self._cleanup_on_exit)

    # ---- Public API -----------------------------------------------------------

    def resolve(self, id_or_preset: "str | ModelPreset") -> ModelPreset:
        if isinstance(id_or_preset, ModelPreset):
            return id_or_preset
        preset = get_preset(id_or_preset)
        if preset is not None:
            return preset
        # Fall back: does it look like a HuggingFace repo? Auto-register.
        from .hf_auto import is_hf_ref, parse_model_ref, from_hf
        if is_hf_ref(id_or_preset):
            repo, quant = parse_model_ref(id_or_preset)
            return from_hf(repo, quant=quant)
        raise RunnerError(
            f"No preset named {id_or_preset!r}. "
            f"Use openhost.list_presets() to see built-ins, "
            f"pass a HuggingFace repo id like 'owner/name' for auto-detect, "
            f"or register one with openhost.register_preset(...)."
        )

    def get(self, id_or_preset: "str | ModelPreset") -> Optional[ModelRunner]:
        preset = self.resolve(id_or_preset)
        return self._runners.get(preset.id)

    def ensure_running(
        self,
        id_or_preset: "str | ModelPreset",
        ready_timeout: float = 180.0,
        draft_model_path: Optional[str] = None,
    ) -> ModelRunner:
        preset = self.resolve(id_or_preset)
        # When speculation is enabled, treat it as a distinct runner instance
        # so a prior non-speculative runner isn't reused silently.
        cache_key = preset.id if not draft_model_path else f"{preset.id}::spec::{draft_model_path}"
        with self._lock:
            existing = self._runners.get(cache_key)
            if existing and existing.is_running:
                return existing
            runner = ModelRunner(preset, draft_model_path=draft_model_path)
            self._runners[cache_key] = runner
        runner.start(ready_timeout=ready_timeout)
        return runner

    def stop(self, id_or_preset: "str | ModelPreset") -> None:
        preset = self.resolve(id_or_preset)
        with self._lock:
            runner = self._runners.pop(preset.id, None)
        if runner:
            runner.stop()

    def stop_all(self) -> None:
        with self._lock:
            runners = list(self._runners.values())
            self._runners.clear()
        for r in runners:
            r.stop()

    def running(self) -> list[ModelRunner]:
        return [r for r in self._runners.values() if r.is_running]

    # ---- Internals ------------------------------------------------------------

    def _cleanup_on_exit(self) -> None:
        try:
            self.stop_all()
        except Exception:
            pass


_instance = _Registry()


def get_registry() -> _Registry:
    return _instance
