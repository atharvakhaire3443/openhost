# Changelog

All notable changes to `openhost` are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [SemVer](https://semver.org/).

## [Unreleased]

## [0.3.0] — 2026-04-18

Out-of-the-box primitives that differentiate `openhost` from every other
local-LLM Python package.

### Added
- `openhost.panel(models, prompt)` — parallel multi-model ensemble with
  optional judge scoring (`judge="model-id"`). Turns a single prompt into a
  mini-eval harness.
- `openhost.extract(text, schema=MyPydanticModel)` — pydantic-validated
  structured output with automatic retry-on-validation-failure. Recovers from
  malformed JSON by feeding errors back to the model. Injects `/no_think` for
  Qwen-family models.
- `openhost.session("name", model=...)` — persistent, branchable chat sessions
  backed by `~/.openhost/sessions.db`. Supports `chat.branch("alt")` to fork
  conversations, survives Python process restarts, resumes where you left off.
- `openhost.memory(id, extractor_model=...)` — Graphiti-inspired temporal
  knowledge-graph memory. Automatically extracts entity/relation triples from
  observed text, supports temporal validity (old facts get "closed" instead of
  overwritten), and offers hybrid graph + FTS5 recall. Integrates directly
  with `session(..., memory=mem)` for automatic context injection.
- `openhost.voice_chat(model)` — mic → VAD → Whisper → LLM loop. Optional
  Piper TTS playback. A complete local voice assistant in one call.
  Requires `openhost[voice]` (mic+VAD) and `openhost[voice-tts]` (spoken replies).
- `make_chat(model, speculate_with="small-draft-model")` — expose llama.cpp's
  speculative decoding (`-md`). 1.5–3× generation throughput when pairing a
  small draft model with a large target model.
- `openhost.from_hf("owner/repo")` — inspect a HuggingFace repo, auto-detect
  backend (GGUF→llama.cpp, safetensors→mlx-lm), pick a sensible quant, and
  register a usable preset. Idempotent. Handles sharded GGUFs (siblings auto-
  added to download set). Every entry point (`pull`, `run`, `make_chat`,
  `chat`, `session`, `memory`, `panel`, `extract`) accepts a raw HF repo id.
  Quant override via `"owner/repo:Q5_K_M"` syntax.
- Custom `httpx.Client` shim (`_qwen_compat`) that folds Qwen's non-standard
  `message.reasoning` field into standard `content` (wrapped in `<think>…`
  tags). Fixes the "empty response" bug that would otherwise surprise users of
  Qwen MLX models via standard LangChain / OpenAI SDK clients.

### Changed
- `ModelRunner.__init__` accepts `draft_model_path` for speculative decoding.
- Registry cache key becomes composite (`<id>::spec::<draft_path>`) so runners
  with/without speculation can coexist.

### Added (optional extras)
- `openhost[voice]` → `sounddevice`, `silero-vad`, `numpy`
- `openhost[voice-tts]` → adds `piper-tts` on top of `voice`
- `openhost[memory-embeddings]` → `sentence-transformers` (memory falls back
  to FTS5 without it)

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
