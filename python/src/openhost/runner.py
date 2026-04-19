"""Subprocess lifecycle for local LLM servers (llama.cpp, mlx-lm).

Each running model is a `ModelRunner` that owns a child process and exposes
an OpenAI-compatible base URL on a dynamically-picked localhost port.
"""
from __future__ import annotations

import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Optional

import httpx

from . import paths
from ._backend import (
    choose_llama_backend,
    translate_llama_command,
    mlx_backend_available,
    warn_if_gpu_unused,
)
from .download import is_present, pull
from .hardware import detect as _detect_hw
from .presets import ModelPreset


_IS_WINDOWS = sys.platform == "win32"


class RunnerError(RuntimeError):
    pass


@dataclass
class RunnerInfo:
    id: str
    pid: int
    port: int
    base_url: str
    upstream_model_id: str


class ModelRunner:
    """Manages one running model server subprocess."""

    def __init__(
        self,
        preset: ModelPreset,
        port: Optional[int] = None,
        extra_args: tuple[str, ...] = (),
        env: Optional[dict[str, str]] = None,
        log_path: Optional[str] = None,
        draft_model_path: Optional[str] = None,
        profile: Optional[str] = None,
        warmup: bool = False,
    ) -> None:
        self.preset = preset
        self._port = port
        self._extra_args = extra_args
        self._env = env
        self._log_path = log_path
        self._draft_model_path = draft_model_path
        self._profile = profile
        self._warmup = warmup
        self._process: Optional[subprocess.Popen] = None
        self._resolved_model_id: Optional[str] = None
        self._lock = threading.Lock()

    # ---- Public properties -----------------------------------------------------

    @property
    def is_running(self) -> bool:
        return self._process is not None and self._process.poll() is None

    @property
    def port(self) -> int:
        if self._port is None:
            raise RunnerError("Runner has no assigned port yet (not started).")
        return self._port

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1"

    @property
    def upstream_model_id(self) -> str:
        if self._resolved_model_id is None:
            raise RunnerError("Upstream model id not resolved yet (call start() first).")
        return self._resolved_model_id

    def info(self) -> RunnerInfo:
        if not self.is_running:
            raise RunnerError("Runner is not running.")
        assert self._process is not None
        return RunnerInfo(
            id=self.preset.id,
            pid=self._process.pid,
            port=self.port,
            base_url=self.base_url,
            upstream_model_id=self.upstream_model_id,
        )

    # ---- Lifecycle -------------------------------------------------------------

    def start(self, download_if_missing: bool = True, ready_timeout: float = 180.0) -> RunnerInfo:
        with self._lock:
            if self.is_running:
                return self.info()

            if not is_present(self.preset):
                if not download_if_missing:
                    raise RunnerError(
                        f"Model {self.preset.id!r} not present locally. "
                        f"Call openhost.pull({self.preset.id!r}) or pass download_if_missing=True."
                    )
                pull(self.preset, progress=True)

            self._check_backend_available()
            if self._port is None:
                self._port = _pick_free_port()

            model_path = str(paths.effective_model_dir(self.preset))
            effective_extra = tuple(self._extra_args)
            if self._draft_model_path:
                if self.preset.backend != "llama.cpp":
                    raise RunnerError(
                        "speculate_with is only supported with the llama.cpp backend "
                        "(mlx_lm.server does not accept a draft-model flag)."
                    )
                effective_extra = effective_extra + (
                    "-md", self._draft_model_path,
                    "-ngld", "99",
                    "--draft-max", "16",
                    "--draft-min", "4",
                )
            cmd = _materialize_command(
                template=list(self.preset.command_template),
                path=model_path,
                port=self._port,
                preset=self.preset,
                extra_args=effective_extra,
            )

            # Profile knob merge (must happen BEFORE backend translation so the
            # llama-server-flavored flag names match).
            if self._profile and self.preset.backend == "llama.cpp":
                from .profiles import get_profile
                cmd = get_profile(self._profile).apply_to(cmd)

            # Hardware-aware tuning + backend translation for llama.cpp presets.
            if self.preset.backend == "llama.cpp":
                cmd = _auto_tune_llama_cmd(cmd, preset=self.preset, model_path=model_path)
                backend = choose_llama_backend()
                warn_if_gpu_unused(backend)
                cmd = translate_llama_command(cmd, backend)

            log_sink = (
                open(self._log_path, "ab", buffering=0)
                if self._log_path
                else subprocess.DEVNULL
            )

            env = os.environ.copy()
            if self._env:
                env.update(self._env)

            popen_kwargs: dict = {
                "stdout": log_sink,
                "stderr": subprocess.STDOUT,
                "env": env,
            }
            if _IS_WINDOWS:
                # Windows: new process group so we can send CTRL_BREAK_EVENT later
                popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
            else:
                # POSIX: detach into a new session for whole-tree signalling
                popen_kwargs["start_new_session"] = True

            self._process = subprocess.Popen(cmd, **popen_kwargs)

            try:
                self._resolved_model_id = _wait_for_upstream(self._port, ready_timeout, self._process)
            except Exception:
                self.stop()
                raise

            if self._warmup:
                try:
                    _warmup_model(self._port, self._resolved_model_id)
                except Exception:
                    # Warmup is best-effort — never fail the start because of it.
                    pass

            return self.info()

    def stop(self) -> None:
        with self._lock:
            if not self._process:
                return
            proc = self._process
            self._process = None
            if proc.poll() is None:
                _terminate_gracefully(proc)
            self._resolved_model_id = None

    def __enter__(self) -> "ModelRunner":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()

    # ---- Internals -------------------------------------------------------------

    def _check_backend_available(self) -> None:
        binary = self.preset.command_template[0] if self.preset.command_template else None
        if not binary:
            raise RunnerError(f"{self.preset.id}: empty command template")

        # llama-server: prefer external binary, fall back to bundled llama-cpp-python.
        if binary == "llama-server":
            try:
                choose_llama_backend()
                return
            except RuntimeError as exc:
                raise RunnerError(str(exc)) from exc

        # mlx_lm.server: check PATH or the bundled package.
        if binary == "mlx_lm.server":
            if mlx_backend_available():
                return
            raise RunnerError(
                f"{self.preset.id}: mlx-lm not available. "
                "On Apple Silicon, this is auto-installed with `pip install openhost`. "
                "On other platforms, MLX is Apple-only — use a llama.cpp preset instead."
            )

        # Other commands (fine-tuning scripts, etc.) — just PATH check.
        if shutil.which(binary) is None:
            raise RunnerError(
                f"{self.preset.id}: required binary {binary!r} not found on PATH. "
                + _install_hint(self.preset)
            )


def _install_hint(preset: ModelPreset) -> str:
    if preset.backend == "llama.cpp":
        return "Install with: brew install llama.cpp"
    if preset.backend == "mlx-lm":
        return "Install with: pip install mlx-lm (Apple Silicon only)"
    return ""


def _pick_free_port() -> int:
    """Grab a free localhost port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _materialize_command(
    *,
    template: list[str],
    path: str,
    port: int,
    preset: ModelPreset,
    extra_args: tuple[str, ...],
) -> list[str]:
    """Expand {placeholders} in the command template."""
    subs = {
        "path": path,
        "port": str(port),
        "id": preset.id,
        "primary_file": preset.primary_file or "",
        "context_length": str(preset.context_length),
    }
    out: list[str] = []
    for tok in template:
        for k, v in subs.items():
            tok = tok.replace("{" + k + "}", v)
        out.append(tok)
    out.extend(extra_args)
    return out


def _wait_for_upstream(port: int, timeout: float, process: subprocess.Popen) -> str:
    """Poll /v1/models until it returns an id, or timeout."""
    url = f"http://127.0.0.1:{port}/v1/models"
    deadline = time.time() + timeout
    last_error: Optional[str] = None

    while time.time() < deadline:
        if process.poll() is not None:
            raise RunnerError(
                f"Server exited during startup (code={process.returncode}). "
                "Check log file if set."
            )
        try:
            r = httpx.get(url, timeout=2.0)
            if r.status_code == 200:
                data = r.json().get("data", [])
                if data and "id" in data[0]:
                    return data[0]["id"]
        except httpx.RequestError as exc:
            last_error = str(exc)
        time.sleep(0.5)

    raise RunnerError(
        f"Server on 127.0.0.1:{port} did not become ready within {timeout}s. "
        f"Last error: {last_error}"
    )


def _warmup_model(port: int, upstream_model_id: str) -> None:
    """Send a tiny prompt so the KV cache + CUDA kernels are ready on first real call."""
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    payload = {
        "model": upstream_model_id,
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 1,
        "temperature": 0.0,
        "stream": False,
    }
    try:
        httpx.post(url, json=payload, timeout=60.0)
    except httpx.HTTPError:
        pass


def _auto_tune_llama_cmd(cmd: list[str], *, preset: ModelPreset, model_path: str) -> list[str]:
    """Adjust llama.cpp command args based on detected hardware + model size.

    - Rewrites ``-ngl`` to the max layers that will fit in available VRAM.
    - Keeps ``-fa on`` / cache quant hints from the preset untouched by default.
    - Never raises; on any probe failure we leave the original command alone.
    """
    try:
        hw = _detect_hw()
    except Exception:
        return cmd

    # Skip auto-tuning on CPU-only hardware — leave whatever the preset said
    # (and trust the user's template). `-ngl 99` is harmless on CPU — llama.cpp
    # just prints a warning if no GPU is present, then runs on CPU.
    if not hw.has_gpu:
        return cmd

    model_file = _primary_model_file(preset, model_path)
    if model_file is None:
        return cmd

    model_size_gb = _file_size_gb(model_file)
    if model_size_gb <= 0.0:
        return cmd

    usable_vram = hw.usable_vram_gb
    if usable_vram <= 0.0:
        return cmd

    # If the model fits comfortably, keep all layers on the GPU.
    if model_size_gb * 1.15 <= usable_vram:
        return _ensure_ngl(cmd, 99)

    # Otherwise, offload the fraction that fits (leave ~10% headroom for KV).
    # Use a conservative bytes-per-layer estimate: model_size / (approx_n_layers).
    approx_layers = _guess_layer_count(preset.id, default=32)
    per_layer_gb = model_size_gb / max(1, approx_layers)
    fittable = int((usable_vram * 0.9) / max(per_layer_gb, 0.01))
    fittable = max(0, min(approx_layers, fittable))
    return _ensure_ngl(cmd, fittable)


def _ensure_ngl(cmd: list[str], value: int) -> list[str]:
    """Replace or insert ``-ngl <N>``."""
    out: list[str] = []
    i = 0
    replaced = False
    while i < len(cmd):
        tok = cmd[i]
        if tok == "-ngl" and i + 1 < len(cmd):
            out.extend(["-ngl", str(value)])
            i += 2
            replaced = True
            continue
        out.append(tok)
        i += 1
    if not replaced:
        out.extend(["-ngl", str(value)])
    return out


def _primary_model_file(preset: ModelPreset, model_path: str) -> Optional[str]:
    if preset.primary_file:
        candidate = os.path.join(model_path, preset.primary_file)
        if os.path.exists(candidate):
            return candidate
    # Otherwise pick the biggest .gguf in the directory, if any.
    try:
        entries = [
            os.path.join(model_path, f)
            for f in os.listdir(model_path)
            if f.endswith(".gguf")
        ]
    except OSError:
        return None
    if not entries:
        return None
    entries.sort(key=os.path.getsize, reverse=True)
    return entries[0]


def _file_size_gb(path: str) -> float:
    try:
        return os.path.getsize(path) / (1024 ** 3)
    except OSError:
        return 0.0


def _guess_layer_count(preset_id: str, default: int) -> int:
    """Rough guess for transformer layer count by parameter count hint.

    Used only for fractional GPU offload sizing; doesn't need to be exact.
    """
    pid = preset_id.lower()
    for marker, layers in (
        ("1b", 22),
        ("3b", 28),
        ("7b", 32),
        ("8b", 32),
        ("13b", 40),
        ("14b", 40),
        ("30b", 60),
        ("32b", 64),
        ("34b", 60),
        ("35b", 64),
        ("70b", 80),
        ("72b", 80),
    ):
        if marker in pid:
            return layers
    return default


def _terminate_gracefully(proc: subprocess.Popen) -> None:
    """Platform-aware process-tree termination."""
    if _IS_WINDOWS:
        try:
            proc.send_signal(signal.CTRL_BREAK_EVENT)  # type: ignore[attr-defined]
        except (OSError, ValueError):
            try:
                proc.terminate()
            except Exception:
                pass
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except Exception:
                pass
    else:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError, AttributeError):
            proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError, AttributeError):
                proc.kill()
