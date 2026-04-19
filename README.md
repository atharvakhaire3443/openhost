# OpenHost

Local LLM infrastructure — a **Python SDK** (on PyPI) and a **macOS desktop app** that share concepts but ship independently.

[![PyPI](https://img.shields.io/pypi/v/openhost.svg)](https://pypi.org/project/openhost/)
[![Python versions](https://img.shields.io/pypi/pyversions/openhost.svg)](https://pypi.org/project/openhost/)
[![License](https://img.shields.io/pypi/l/openhost.svg)](./python/LICENSE)

---

## What's here

This repo has two products that share a mission — making local LLMs frictionless to run — but target different audiences:

| | Path | Audience | Distribution |
|---|---|---|---|
| **`openhost` Python SDK** | `python/` | Python developers, LangChain users, automation | [PyPI](https://pypi.org/project/openhost/) |
| **OpenHost macOS app** | `Sources/`, `Package.swift` | Desktop users who want a GUI | Build from source (`swift build` or `./scripts/make-app.sh`) |

Both run local models (llama.cpp on all platforms, Apple MLX on Apple Silicon) and speak OpenAI-compatible HTTP internally. Neither depends on the other.

---

## Python SDK — one-install on every platform

```bash
pip install openhost
```

One command gets you a working llama.cpp runtime on macOS, Linux, and Windows. On Apple Silicon you also get the MLX backend. For NVIDIA/AMD GPU acceleration, one extra wheel install (see [`python/README.md`](./python/README.md)).

```python
import openhost

# Auto-downloads, picks the right quant, auto-tunes GPU offload, streams back
llm = openhost.make_chat("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF", streaming=True)
for chunk in llm.stream("Explain monads in a single paragraph."):
    print(chunk.content, end="", flush=True)
```

### What the SDK ships

- **Zero-config model runners** for `llama.cpp` (bundled via `llama-cpp-python`) and Apple MLX (`mlx-lm`)
- **`from_hf()`** — auto-detect backend, pick quant, handle sharded GGUFs, register any HuggingFace repo as a preset
- **Hardware-aware tuning** — auto-picks GPU offload layers, KV cache quant, batch size based on detected RAM/VRAM
- **Profiles** — `run(model, profile="fast" | "quality" | "lowmem" | "balanced")`
- **LangChain-native** — `make_chat()` returns a preconfigured `ChatOpenAI`
- **`panel()`** — parallel multi-model ensemble with judge scoring
- **`extract()`** — pydantic-validated structured output with retry loop
- **`session()`** — persistent, branchable chat sessions (SQLite)
- **`memory()`** — Graphiti-style temporal knowledge-graph memory
- **`voice_chat()`** — mic → Whisper → LLM loop (optional Piper TTS)
- **`openhost doctor`** — diagnose install, hardware, GPU readiness

Full SDK docs: [`python/README.md`](./python/README.md). Changelog: [`python/CHANGELOG.md`](./python/CHANGELOG.md).

---

## macOS app

A SwiftUI app that manages local model servers with a proper chat UI — for people who prefer a desktop experience over a Python REPL.

**Highlights:**
- Start/stop/swap local llama.cpp + MLX model servers
- Streaming chat with stats (TTFT, tok/s, context gauge)
- WhisperKit on-device transcription (Apple Neural Engine)
- Markdown rendering with `<think>` block folding
- Document / PDF / image attach, web search tool integration
- Optional Hummingbird HTTP gateway to expose running models to external clients

**Build it:**

```bash
swift build -c release
./scripts/make-app.sh              # produces OpenHost.app with proper Info.plist
open OpenHost.app
```

Details in the Swift sources under [`Sources/OpenHost/`](./Sources/OpenHost/).

---

## Repo layout

```
OpenHost/
├── README.md                     ← this file
├── python/                       ← openhost Python SDK (PyPI)
│   ├── src/openhost/
│   ├── pyproject.toml
│   ├── README.md
│   ├── CHANGELOG.md
│   ├── LICENSE
│   └── RELEASING.md
├── Sources/OpenHost/             ← SwiftUI macOS app
├── Package.swift
├── scripts/
│   ├── make-app.sh               ← bundle the binary into OpenHost.app
│   └── Info.plist
├── examples/                     ← end-to-end Python usage examples
└── .github/workflows/
    ├── ci.yml                    ← lint + build matrix (ubuntu / macos / windows)
    └── publish.yml               ← tag-triggered PyPI release (OIDC trusted publishing)
```

## License

MIT — see [`python/LICENSE`](./python/LICENSE).
