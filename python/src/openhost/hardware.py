"""Runtime hardware detection — used to auto-tune llama.cpp / MLX runners
based on what the machine actually has.

Graceful: every probe is wrapped; failures fall back to conservative defaults.
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class HardwareSnapshot:
    platform: str                       # "darwin" | "linux" | "windows"
    arch: str                           # "arm64" | "x86_64" | ...
    cpu_cores: int
    ram_gb: float                       # total system RAM
    ram_available_gb: float             # currently free
    has_metal: bool                     # Apple GPU via Metal
    nvidia_vram_gb: float = 0.0         # sum across NVIDIA GPUs (0 if none)
    nvidia_gpus: list[str] = field(default_factory=list)
    has_rocm: bool = False              # AMD ROCm present

    @property
    def has_gpu(self) -> bool:
        return self.has_metal or self.nvidia_vram_gb > 0 or self.has_rocm

    @property
    def usable_vram_gb(self) -> float:
        """Effective VRAM available for model weights (leaves a safety buffer)."""
        if self.nvidia_vram_gb > 0:
            return max(0.0, self.nvidia_vram_gb - 1.5)   # reserve ~1.5GB for KV + overhead
        if self.has_metal:
            # On Apple Silicon, VRAM is unified with RAM. Treat ~60% of RAM as
            # Metal-usable; macOS reserves a chunk for the OS.
            return self.ram_gb * 0.6
        return 0.0

    def describe(self) -> str:
        bits: list[str] = [
            f"{self.platform}/{self.arch}",
            f"{self.cpu_cores} cores",
            f"{self.ram_gb:.1f}G RAM ({self.ram_available_gb:.1f}G free)",
        ]
        if self.nvidia_vram_gb > 0:
            bits.append(f"NVIDIA {self.nvidia_vram_gb:.1f}G VRAM")
        if self.has_metal:
            bits.append("Metal")
        if self.has_rocm:
            bits.append("ROCm")
        return ", ".join(bits)


_SNAPSHOT_CACHE: Optional[HardwareSnapshot] = None


def detect(force: bool = False) -> HardwareSnapshot:
    """Return a cached hardware snapshot. Override with `force=True` to re-probe."""
    global _SNAPSHOT_CACHE
    if _SNAPSHOT_CACHE is not None and not force:
        return _SNAPSHOT_CACHE
    _SNAPSHOT_CACHE = _probe()
    return _SNAPSHOT_CACHE


def _probe() -> HardwareSnapshot:
    system = platform.system().lower()
    arch = platform.machine().lower()
    cpu_cores = os.cpu_count() or 1
    ram_gb = _probe_ram_gb()
    ram_available_gb = _probe_ram_available_gb()
    has_metal = system == "darwin" and arch == "arm64"
    nvidia_vram_gb, nvidia_gpus = _probe_nvidia()
    has_rocm = _probe_rocm()
    return HardwareSnapshot(
        platform=system,
        arch=arch,
        cpu_cores=cpu_cores,
        ram_gb=ram_gb,
        ram_available_gb=ram_available_gb,
        has_metal=has_metal,
        nvidia_vram_gb=nvidia_vram_gb,
        nvidia_gpus=nvidia_gpus,
        has_rocm=has_rocm,
    )


def _probe_ram_gb() -> float:
    # Try psutil first (optional dep); fall back to platform-specific probes.
    try:
        import psutil
        return psutil.virtual_memory().total / (1024 ** 3)
    except Exception:
        pass
    try:
        if platform.system() == "Darwin":
            out = subprocess.check_output(["sysctl", "-n", "hw.memsize"], timeout=2).decode().strip()
            return int(out) / (1024 ** 3)
        if platform.system() == "Linux":
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        return kb / (1024 ** 2)
        if platform.system() == "Windows":
            import ctypes
            class MEMSTAT(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong),
                            ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong),
                            ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong),
                            ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong),
                            ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("sullAvailExtendedVirtual", ctypes.c_ulonglong)]
            stat = MEMSTAT()
            stat.dwLength = ctypes.sizeof(stat)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat))
            return stat.ullTotalPhys / (1024 ** 3)
    except Exception:
        pass
    return 8.0  # conservative fallback


def _probe_ram_available_gb() -> float:
    try:
        import psutil
        return psutil.virtual_memory().available / (1024 ** 3)
    except Exception:
        # fall back to total
        return _probe_ram_gb() * 0.7


def _probe_nvidia() -> tuple[float, list[str]]:
    """Return (total_vram_gb, gpu_names) via nvidia-smi if present."""
    if shutil.which("nvidia-smi") is None:
        return 0.0, []
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total",
                "--format=csv,noheader,nounits",
            ],
            timeout=3,
        ).decode().strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, FileNotFoundError):
        return 0.0, []
    names: list[str] = []
    total_mib = 0
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 2:
            names.append(parts[0])
            try:
                total_mib += int(parts[1])
            except ValueError:
                continue
    return total_mib / 1024.0, names


def _probe_rocm() -> bool:
    if shutil.which("rocminfo"):
        return True
    # HIP-visible devices env set
    if os.environ.get("HIP_VISIBLE_DEVICES"):
        return True
    return False
