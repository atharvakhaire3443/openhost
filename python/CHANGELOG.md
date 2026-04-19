# Changelog

All notable changes to `openhost` are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [SemVer](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-04-19

A big release. Combines the new primitives that were developed as 0.3.0
(never published — superseded by this release) with the cross-platform
install story and hardware-aware optimizations.

### Added — zero-config cross-platform install
- **Bundled `llama-cpp-python` backend.** `pip install openhost` now ships a
  working llama.cpp runtime on macOS, Linux, and Windows — no `brew install
  llama.cpp` or hand-building required. External `llama-server` on PATH is
  still preferred when present (faster startup).
- **Conditional `mlx-lm` on Apple Silicon** — auto-installed only on macOS
  arm64 where MLX can actually run. Skipped on other platforms.
- **Windows subprocess supervision.** `CREATE_NEW_PROCESS_GROUP` +
  `CTRL_BREAK_EVENT` replaces POSIX `setsid` / `killpg`. Clean shutdown on
  all three platforms.
- **Cross-platform CI.** GitHub Actions matrix runs `ubuntu-latest`,
  `macos-14`, and `windows-latest`.

### Added — hardware-aware optimization
- **`openhost.hardware.detect()`** — runtime probe for RAM, VRAM (via
  `nvidia-smi`), Metal availability, CPU count, ROCm presence.
- **Auto-tuned `-ngl` (GPU layer offload)** based on detected VRAM and
  actual GGUF file size. Full offload when the model fits; fractional
  offload when it doesn't.
- **Profiles:** `openhost.run(model, profile="fast" | "quality" | "lowmem"
  | "balanced")`. Bundles context size, KV cache quant, batch size. Also
  threaded through `make_chat(..., profile=...)`.
- **Warmup on start:** `run(..., warmup=True)` / `make_chat(..., warmup=True)`
  sends a 1-token request after readiness so the first real call isn't cold.
- **`openhost doctor` / `openhost.check_setup()`** — diagnose the install:
  prints detected hardware, active llama.cpp backend, GPU-enabled status,
  and the exact fix command if GPU acceleration isn't wired up.
- **First-run GPU-unused warning** — if we detect NVIDIA/ROCm hardware but
  the installed `llama-cpp-python` is CPU-only, we print the exact
  `--extra-index-url` reinstall command once on stderr.

### Added — primitives (previously tracked under 0.3.0, never released)
- `openhost.panel(models, prompt, judge=...)` — parallel multi-model ensemble
  with optional judge scoring. Mini-eval harness in one call.
- `openhost.extract(text, schema=PydanticModel)` — pydantic-validated
  structured output with automatic retry loop. Injects `/no_think` for
  Qwen-family models.
- `openhost.session("name", model=...)` — persistent, branchable chat
  sessions backed by `~/.openhost/sessions.db`. Supports `chat.branch("alt")`
  forks; survives Python process restarts.
- `openhost.memory(id, extractor_model=...)` — Graphiti-inspired temporal
  knowledge-graph memory. Extracts triples from observed text, tracks
  valid-time (old facts get "closed"), hybrid graph + FTS5 recall.
  `session(..., memory=mem)` auto-integrates.
- `openhost.voice_chat(model)` — mic → silero-VAD → Whisper → LLM loop.
  Optional Piper TTS (extras `openhost[voice]` and `openhost[voice-tts]`).
- `make_chat(model, speculate_with="small-draft-model")` — expose llama.cpp
  speculative decoding via `-md` for 1.5–3× generation speedup.
- `openhost.from_hf("owner/repo")` — inspect a HuggingFace repo, auto-detect
  backend (GGUF→llama.cpp, safetensors→mlx-lm), pick a quant, register a
  preset. Idempotent. Handles sharded GGUFs. Every entry point accepts a
  raw HF repo id. Quant override via `"owner/repo:Q5_K_M"`.
- Custom `httpx.Client` shim (`_qwen_compat`) that folds Qwen's non-standard
  `message.reasoning` field into standard `content` wrapped in `<think>…`
  tags. Fixes the "empty response" bug for Qwen MLX users.

### Changed
- `Operating System :: Microsoft :: Windows` classifier on PyPI.
- `ModelRunner.__init__` accepts `draft_model_path`, `profile`, `warmup`.
- Registry cache keys include profile/speculation components so different
  configurations of the same model coexist as distinct runners.
- `transcription.auto` skips the MLX probe on non-Apple-Silicon and gives
  platform-appropriate install hints.

### Optional extras
- `openhost[whisper-mlx]` — Apple Neural Engine whisper
- `openhost[whisper-faster]` — CPU / CUDA whisper (faster-whisper)
- `openhost[voice]` — sounddevice + silero-vad + numpy
- `openhost[voice-tts]` — adds piper-tts on top of [voice]
- `openhost[memory-embeddings]` — sentence-transformers (memory falls back to
  FTS5 without it)
- `openhost[cuda]` / `openhost[rocm]` — placeholder extras; see README for the
  `--extra-index-url` reinstall that actually enables GPU acceleration

## [0.2.1] — 2026-04-18

### Fixed
- `Homepage`, `Repository`, `Issues`, and `Changelog` URLs in PyPI metadata now
  point at the real repo (`github.com/atharvakhaire3443/openhost`).
- `Author-email` populated for PyPI moderation replies.

## [0.2.0] — 2026-04-18

### Changed
- **Complete rewrite as a pure-Python package.** Zero Swift dependency.
- `openhost.make_chat(id)` auto-starts the model and returns a preconfigured
  LangChain `ChatOpenAI`. No HTTP gateway involved — direct connection to
  `llama.cpp` / `mlx-lm` on a free localhost port.
- `openhost.pull(id)` now downloads via `huggingface_hub` to `~/.openhost/models/<id>/`.

### Added
- Built-in presets: `qwen3.6-35b-mlx-turbo`, `qwen3.5-35b-uncensored`, `qwen3-8b-gguf`.
- `register_local_model(...)` — register an existing model directory without
  re-downloading.
- `OpenHostSearchTool` (LangChain `BaseTool`) with DuckDuckGo, Tavily, Brave,
  and SearXNG providers.
- `openhost.transcribe(path)` + `OpenHostWhisper` LangChain loader. Backends
  available via extras: `[whisper-mlx]` (Apple Silicon) and `[whisper-faster]`
  (CPU/CUDA).
- `openhost` CLI: `list`, `pull`, `run`, `running`, `stop`.

### Removed
- `OpenHostServer` (launched the Swift binary) — no longer needed.
- HTTP gateway client (`OpenHost` class that talked to Swift). The Swift app
  still exists and still has its own gateway, but the Python SDK no longer
  depends on it.

## [0.1.0] — 2026-04-18

Initial Swift-backed release. Retired in favor of 0.2.0.
