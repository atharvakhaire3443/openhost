# Changelog

All notable changes to `openhost` are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [SemVer](https://semver.org/).

## [Unreleased]

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
