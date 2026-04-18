"""Voice chat loop: microphone → VAD → Whisper → LLM (→ optional TTS).

    import openhost
    openhost.voice_chat("qwen3-8b-gguf")

Requires extras:
    pip install "openhost[voice]"         # mic + VAD + whisper
    pip install "openhost[voice-tts]"     # + Piper TTS playback

Press Ctrl+C to stop.
"""
from __future__ import annotations

import os
import queue
import sys
import tempfile
import threading
import wave
from dataclasses import dataclass
from typing import Callable, Optional

from .chat import make_chat


TARGET_SR = 16000           # Whisper + Silero VAD native
BLOCK_MS = 32               # 32ms mic chunks (~512 samples @ 16kHz)
SILENCE_MS = 700            # end-of-utterance threshold
MIN_UTTERANCE_MS = 400      # drop anything shorter
MAX_UTTERANCE_SEC = 30


@dataclass
class _TTS:
    cmd_template: list[str]
    audio_player: list[str]


class _VoiceDeps:
    """Lazy import of the optional-extras deps."""

    def __init__(self) -> None:
        try:
            import sounddevice as sd
            import numpy as np
        except ImportError as exc:  # noqa: BLE001
            raise ImportError(
                "voice_chat requires sounddevice + numpy. "
                "Install with: pip install 'openhost[voice]'"
            ) from exc
        self.sd = sd
        self.np = np

        try:
            from silero_vad import load_silero_vad, VADIterator
        except ImportError as exc:  # noqa: BLE001
            raise ImportError(
                "voice_chat requires silero-vad. "
                "Install with: pip install 'openhost[voice]'"
            ) from exc
        self.load_silero_vad = load_silero_vad
        self.VADIterator = VADIterator


def voice_chat(
    model: str,
    *,
    system: Optional[str] = None,
    tts: Optional[str] = None,      # e.g. "piper:en_US-amy-medium"
    on_transcript: Optional[Callable[[str], None]] = None,
    max_tokens: int = 1024,
    temperature: float = 0.7,
) -> None:
    """Open a mic → whisper → LLM loop. Streams replies to stdout.

    Args:
        model: openhost model id to chat with.
        system: optional system prompt.
        tts: ``"piper:<voice-name>"`` to speak replies. Requires ``openhost[voice-tts]``.
        on_transcript: optional callback when a user utterance is transcribed.
    """
    deps = _VoiceDeps()
    from langchain_core.messages import SystemMessage

    from .transcription import make_default_transcriber
    transcriber = make_default_transcriber()

    vad_model = deps.load_silero_vad()
    tts_adapter = _build_tts(tts) if tts else None

    llm = make_chat(
        model,
        streaming=True,
        max_tokens=max_tokens,
        temperature=temperature,
    )
    history: list = []
    if system:
        history.append(SystemMessage(content=system))

    audio_q: "queue.Queue[bytes]" = queue.Queue()
    stop_event = threading.Event()

    def _mic_cb(indata, frames, time_info, status):  # noqa: ARG001
        if status:
            print(f"[mic] {status}", file=sys.stderr)
        audio_q.put(bytes(indata))

    print(f"[voice] listening — Ctrl+C to stop. Model: {model}")

    block = int(TARGET_SR * BLOCK_MS / 1000)
    utt_samples: list[bytes] = []
    silence_blocks = 0
    in_speech = False
    max_speech_blocks = int(MAX_UTTERANCE_SEC * 1000 / BLOCK_MS)
    silence_threshold_blocks = int(SILENCE_MS / BLOCK_MS)
    min_speech_samples = int(TARGET_SR * MIN_UTTERANCE_MS / 1000)
    speech_block_count = 0

    try:
        with deps.sd.RawInputStream(
            samplerate=TARGET_SR,
            blocksize=block,
            channels=1,
            dtype="int16",
            callback=_mic_cb,
        ):
            while not stop_event.is_set():
                try:
                    chunk = audio_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                # Decide speech vs silence. silero_vad wants float32 in [-1, 1].
                arr = deps.np.frombuffer(chunk, dtype="int16").astype("float32") / 32768.0
                import torch  # silero-vad installs torch
                prob = float(vad_model(torch.from_numpy(arr), TARGET_SR))
                is_speech = prob > 0.5

                if is_speech:
                    in_speech = True
                    utt_samples.append(chunk)
                    silence_blocks = 0
                    speech_block_count += 1
                    if speech_block_count >= max_speech_blocks:
                        _flush_and_run(
                            utt_samples,
                            transcriber, llm, history,
                            tts_adapter, on_transcript,
                        )
                        utt_samples = []
                        in_speech = False
                        speech_block_count = 0
                elif in_speech:
                    utt_samples.append(chunk)  # include trailing silence for natural boundaries
                    silence_blocks += 1
                    if silence_blocks >= silence_threshold_blocks:
                        total_samples = sum(len(c) for c in utt_samples) // 2  # 16-bit
                        if total_samples >= min_speech_samples:
                            _flush_and_run(
                                utt_samples,
                                transcriber, llm, history,
                                tts_adapter, on_transcript,
                            )
                        utt_samples = []
                        in_speech = False
                        silence_blocks = 0
                        speech_block_count = 0
    except KeyboardInterrupt:
        print("\n[voice] stopped.")


def _flush_and_run(
    utt_chunks: list[bytes],
    transcriber,
    llm,
    history: list,
    tts_adapter: Optional[_TTS],
    on_transcript: Optional[Callable[[str], None]],
) -> None:
    audio_bytes = b"".join(utt_chunks)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        path = tmp.name
    try:
        _write_wav(path, audio_bytes)
        result = transcriber.transcribe(path)
        text = (result.text or "").strip()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass

    if not text:
        return

    if on_transcript:
        try:
            on_transcript(text)
        except Exception:
            pass

    from langchain_core.messages import HumanMessage, AIMessage
    print(f"\n> {text}")
    history.append(HumanMessage(content=text))
    reply_parts: list[str] = []
    print("< ", end="", flush=True)
    for chunk in llm.stream(history):
        piece = getattr(chunk, "content", "") or ""
        print(piece, end="", flush=True)
        reply_parts.append(piece)
    print()
    reply = "".join(reply_parts).strip()
    history.append(AIMessage(content=reply))

    if tts_adapter and reply:
        _speak(tts_adapter, reply)


def _write_wav(path: str, pcm16: bytes) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TARGET_SR)
        w.writeframes(pcm16)


def _build_tts(spec: str) -> _TTS:
    """Parse a ``tts`` string like ``piper:en_US-amy-medium`` into a runnable command."""
    if spec.startswith("piper:"):
        voice = spec.split(":", 1)[1]
        try:
            import piper_tts  # noqa: F401
        except ImportError as exc:
            raise ImportError(
                "piper:* TTS requires: pip install 'openhost[voice-tts]'"
            ) from exc
        # piper reads text from stdin, writes WAV to stdout
        return _TTS(
            cmd_template=["piper", "--model", voice, "--output-raw"],
            audio_player=[],  # we pipe to sounddevice directly
        )
    raise ValueError(f"unknown tts spec: {spec!r}. Try 'piper:en_US-amy-medium'.")


def _speak(tts: _TTS, text: str) -> None:
    import subprocess
    try:
        proc = subprocess.Popen(
            tts.cmd_template,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        assert proc.stdin is not None and proc.stdout is not None
        proc.stdin.write(text.encode("utf-8"))
        proc.stdin.close()
        pcm = proc.stdout.read()
        proc.wait(timeout=30)
        _play_pcm(pcm)
    except Exception as exc:
        print(f"[tts] failed: {exc}", file=sys.stderr)


def _play_pcm(pcm: bytes, sr: int = 22050) -> None:
    try:
        import sounddevice as sd
        import numpy as np
        arr = np.frombuffer(pcm, dtype="int16")
        sd.play(arr, sr)
        sd.wait()
    except Exception as exc:
        print(f"[tts playback] failed: {exc}", file=sys.stderr)


def _vad_roundtrip_test(wav_path: str, model: str = "qwen3-8b-gguf") -> str:
    """Non-interactive smoke test used by the test suite: feed a WAV through
    the transcriber + LLM, bypassing mic capture. Returns the LLM reply."""
    from .transcription import make_default_transcriber
    tr = make_default_transcriber().transcribe(wav_path)
    llm = make_chat(model, streaming=False, max_tokens=128)
    from langchain_core.messages import HumanMessage
    resp = llm.invoke([HumanMessage(content=tr.text)])
    return getattr(resp, "content", "") or ""
