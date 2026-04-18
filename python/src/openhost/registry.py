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
        if preset is None:
            raise RunnerError(
                f"No preset named {id_or_preset!r}. "
                f"Use openhost.list_presets() to see available options, "
                f"or register one with openhost.register_preset(...)."
            )
        return preset

    def get(self, id_or_preset: "str | ModelPreset") -> Optional[ModelRunner]:
        preset = self.resolve(id_or_preset)
        return self._runners.get(preset.id)

    def ensure_running(
        self,
        id_or_preset: "str | ModelPreset",
        ready_timeout: float = 180.0,
    ) -> ModelRunner:
        preset = self.resolve(id_or_preset)
        with self._lock:
            existing = self._runners.get(preset.id)
            if existing and existing.is_running:
                return existing
            runner = ModelRunner(preset)
            self._runners[preset.id] = runner
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
