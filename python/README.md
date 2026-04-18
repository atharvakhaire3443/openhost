# openhost

Run local LLMs from Python. LangChain-compatible. No desktop app required.

`openhost` is a thin Python SDK that manages `llama.cpp` and `mlx-lm` servers as subprocesses, handles model downloads from HuggingFace, and plugs into LangChain like any other provider.

## Install

```bash
pip install openhost

# Whisper backend (pick one based on your hardware)
pip install 'openhost[whisper-mlx]'     # Apple Silicon (fast, Neural Engine)
pip install 'openhost[whisper-faster]'  # CPU or CUDA GPUs
```

Runtime backends you install separately:
```bash
brew install llama.cpp        # or build from source
pip install mlx-lm            # Apple Silicon only
```

## Usage

### Quickest path: chat

```python
import openhost

llm = openhost.make_chat("qwen3.6-35b-mlx-turbo", streaming=True)
for chunk in llm.stream("Write a haiku about subprocess management."):
    print(chunk.content, end="", flush=True)
```

That one line auto-downloads the model on first run, starts the server, picks a free port, and returns a fully-wired `ChatOpenAI`. No ports, no YAML, no gateway.

### Model management

```python
openhost.list_presets()                         # all built-in presets
openhost.pull("qwen3.5-35b-uncensored")         # just download
openhost.run("qwen3.5-35b-uncensored")          # start (auto-pulls if needed)
openhost.running()                              # list active runners
openhost.stop("qwen3.5-35b-uncensored")
openhost.stop_all()                             # kill everything
```

### Any HuggingFace model — auto-detect from the repo id

If the model isn't in the built-in presets, just pass a HF repo string. OpenHost
will inspect the repo, pick the right backend (GGUF → llama.cpp, safetensors →
MLX), pick a quant, and register it on the fly.

```python
# Llama 3.1 8B Q4_K_M (default quant pick) — downloads + runs in one call
llm = openhost.make_chat("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")

# Pick a specific quant
llm = openhost.make_chat("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q5_K_M")

# MLX model on Apple Silicon
llm = openhost.make_chat("mlx-community/Qwen2.5-7B-Instruct-4bit")

# More control
from openhost import from_hf
preset = from_hf(
    "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
    filename="Meta-Llama-3.1-8B-Instruct-Q8_0.gguf",  # explicit file
    context_length=8192,
)
```

Register your own model:

```python
from openhost import ModelPreset, register_preset

register_preset(ModelPreset(
    id="llama-3.1-8b-instruct-q6",
    display_name="Llama 3.1 8B Instruct (Q6_K)",
    backend="llama.cpp",
    hf_repo="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
    primary_file="Meta-Llama-3.1-8B-Instruct-Q6_K.gguf",
    command_template=(
        "llama-server", "-m", "{path}/{primary_file}",
        "-c", "{context_length}", "--host", "127.0.0.1", "--port", "{port}",
        "--jinja", "-ngl", "99", "-fa", "on",
    ),
    context_length=8192,
))
```

### Web search (LangChain tool)

```python
from openhost import OpenHostSearchTool

tool = OpenHostSearchTool()  # keyless DuckDuckGo by default
print(tool.invoke("macOS 26 release date"))

# Use a different provider
from openhost.search import TavilyProvider
tool = OpenHostSearchTool(provider=TavilyProvider("tvly-..."))

# Plug into a LangGraph agent
from langgraph.prebuilt import create_react_agent
agent = create_react_agent(llm, tools=[OpenHostSearchTool()])
```

### Transcription

```python
import openhost

# Auto-picks mlx-whisper on Apple Silicon, faster-whisper elsewhere
result = openhost.transcribe("meeting.mp3")
print(result.text)

# As a LangChain document loader (verbose = per-segment Documents)
from openhost import OpenHostWhisper
docs = OpenHostWhisper("meeting.mp3", verbose=True).load()
for doc in docs:
    print(f"[{doc.metadata['start']:.1f}s] {doc.page_content}")
```

### CLI

```bash
openhost list                            # show presets
openhost pull qwen3.5-35b-uncensored     # download
openhost run qwen3.5-35b-uncensored      # foreground until Ctrl-C
```

## Built-in presets

| id                             | backend    | size    |
|--------------------------------|------------|---------|
| `qwen3.6-35b-mlx-turbo`        | mlx-lm     | ~20 GB  |
| `qwen3.5-35b-uncensored`       | llama.cpp  | ~30 GB  |
| `qwen3-8b-gguf`                | llama.cpp  | ~5 GB   |

## How it works

- **No HTTP gateway.** `make_chat()` returns a `ChatOpenAI` pointed straight at the model's own OpenAI-compatible endpoint. Zero proxy overhead.
- **Automatic port allocation.** Each runner picks a free localhost port. Users never touch ports.
- **Process-scoped lifecycle.** When your Python process exits, all runners it started get cleaned up (SIGTERM on the process group, SIGKILL fallback).
- **Platform support.** macOS + Linux. MLX is Apple Silicon only; llama.cpp is cross-platform.

## License

MIT
