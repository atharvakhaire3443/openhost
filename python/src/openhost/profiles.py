"""Performance/memory profiles — bundles of llama.cpp tuning knobs.

Apply at runner-start time via ``openhost.run(..., profile=...)`` or
``make_chat(..., profile=...)``. Not passed through for MLX (mlx_lm.server
auto-tunes most of this itself on Apple Silicon).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


ProfileName = Literal["fast", "quality", "lowmem", "balanced"]


@dataclass(frozen=True)
class Profile:
    name: str
    description: str
    # llama.cpp flag overrides (dash-separated, same shape as preset command_template)
    overrides: tuple[tuple[str, str | None], ...]
    # When True, the caller should also attempt a speculative-decoding draft model.
    wants_speculation: bool = False

    def apply_to(self, cmd: list[str]) -> list[str]:
        """Merge our overrides into an existing llama-server-style command."""
        out = list(cmd)
        for flag, value in self.overrides:
            out = _replace_or_append(out, flag, value)
        return out


PROFILES: dict[str, Profile] = {
    "fast": Profile(
        name="fast",
        description="Favor latency: smaller context, cheaper KV cache, bigger batches.",
        overrides=(
            ("-c", "8192"),
            ("--cache-type-k", "q4_0"),
            ("--cache-type-v", "q4_0"),
            ("-b", "1024"),
            ("-ub", "256"),
            ("-fa", "on"),
        ),
    ),
    "quality": Profile(
        name="quality",
        description="Favor output quality: full context, lossless KV, speculative decoding if available.",
        overrides=(
            ("-c", "32768"),
            ("--cache-type-k", "f16"),
            ("--cache-type-v", "f16"),
            ("-fa", "on"),
        ),
        wants_speculation=True,
    ),
    "lowmem": Profile(
        name="lowmem",
        description="Minimize RAM/VRAM use: tiny context, aggressive KV quant, small batches.",
        overrides=(
            ("-c", "4096"),
            ("--cache-type-k", "q4_0"),
            ("--cache-type-v", "q4_0"),
            ("-b", "256"),
            ("-ub", "64"),
            ("-fa", "on"),
        ),
    ),
    "balanced": Profile(
        name="balanced",
        description="Moderate defaults — good for most laptops.",
        overrides=(
            ("-c", "16384"),
            ("--cache-type-k", "q8_0"),
            ("--cache-type-v", "q8_0"),
            ("-fa", "on"),
        ),
    ),
}


def get_profile(name: str) -> Profile:
    try:
        return PROFILES[name]
    except KeyError:
        raise ValueError(
            f"Unknown profile {name!r}. Choose one of: {', '.join(PROFILES)}"
        )


def _replace_or_append(cmd: list[str], flag: str, value: str | None) -> list[str]:
    out: list[str] = []
    i = 0
    replaced = False
    while i < len(cmd):
        tok = cmd[i]
        if tok == flag:
            # Skip the old value (if any) and substitute.
            if value is not None:
                out.extend([flag, value])
                i += 2 if i + 1 < len(cmd) else 1
            else:
                out.append(flag)
                i += 1
            replaced = True
            continue
        out.append(tok)
        i += 1
    if not replaced:
        if value is not None:
            out.extend([flag, value])
        else:
            out.append(flag)
    return out
