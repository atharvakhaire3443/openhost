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
import threading
import time
from dataclasses import dataclass
from typing import Optional

import httpx

from . import paths
from .download import is_present, pull
from .presets import ModelPreset


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
    ) -> None:
        self.preset = preset
        self._port = port
        self._extra_args = extra_args
        self._env = env
        self._log_path = log_path
        self._draft_model_path = draft_model_path
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

            log_sink = (
                open(self._log_path, "ab", buffering=0)
                if self._log_path
                else subprocess.DEVNULL
            )

            env = os.environ.copy()
            if self._env:
                env.update(self._env)

            self._process = subprocess.Popen(
                cmd,
                stdout=log_sink,
                stderr=subprocess.STDOUT,
                env=env,
                start_new_session=True,
            )

            try:
                self._resolved_model_id = _wait_for_upstream(self._port, ready_timeout, self._process)
            except Exception:
                self.stop()
                raise

            return self.info()

    def stop(self) -> None:
        with self._lock:
            if not self._process:
                return
            proc = self._process
            self._process = None
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    proc.terminate()
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        proc.kill()
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
