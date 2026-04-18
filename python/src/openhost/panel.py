"""Parallel multi-model ensemble.

    from openhost import panel
    results = panel(["qwen3-8b-gguf", "qwen3.6-35b-mlx-turbo"], "Hello")
    for r in results: print(r.model_id, r.text[:40])

Fans out one prompt to N local models concurrently. Optional ``judge`` runs a
second pass scoring each output so you get a tiny eval harness in one call.
"""
from __future__ import annotations

import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any, Optional

from .chat import make_chat
from .presets import ModelPreset


@dataclass
class PanelResult:
    model_id: str
    text: str
    latency_sec: float
    tokens_per_sec: float
    score: Optional[float] = None
    error: Optional[str] = None


_DEFAULT_JUDGE_RUBRIC = """\
You are an impartial evaluator. Score the RESPONSE to the PROMPT on a 0-10 scale:
- Relevance to the prompt
- Factual correctness
- Clarity and coherence

Output ONLY a single floating-point number between 0 and 10. No explanation.

PROMPT:
{prompt}

RESPONSE:
{response}

Score:"""


def panel(
    models: list[str | ModelPreset],
    prompt: str,
    *,
    system: str | None = None,
    max_tokens: int = 1024,
    temperature: float = 0.7,
    judge: Optional[str | ModelPreset] = None,
    judge_rubric: str = _DEFAULT_JUDGE_RUBRIC,
    max_parallel: int = 4,
    timeout: float = 600,
    chat_kwargs: Optional[dict[str, Any]] = None,
) -> list[PanelResult]:
    """Run ``prompt`` across every model in ``models`` in parallel and return results.

    If ``judge`` is set, each result gets rated 0-10 by that model.
    """
    chat_kwargs = dict(chat_kwargs or {})
    chat_kwargs.setdefault("max_tokens", max_tokens)
    chat_kwargs.setdefault("temperature", temperature)
    chat_kwargs.setdefault("timeout", timeout)

    with ThreadPoolExecutor(max_workers=max(1, min(max_parallel, len(models)))) as pool:
        futures = {
            pool.submit(_run_one, model=m, prompt=prompt, system=system, kwargs=chat_kwargs): m
            for m in models
        }
        ordered: dict[Any, PanelResult] = {}
        for fut in as_completed(futures):
            model = futures[fut]
            try:
                ordered[model] = fut.result()
            except Exception as exc:
                mid = model.id if isinstance(model, ModelPreset) else str(model)
                ordered[model] = PanelResult(
                    model_id=mid, text="", latency_sec=0.0, tokens_per_sec=0.0, error=str(exc)
                )

    results = [ordered[m] for m in models]

    if judge:
        _score_results(results, prompt, judge, judge_rubric)

    return results


def _run_one(
    model: Any,
    prompt: str,
    system: str | None,
    kwargs: dict[str, Any],
) -> PanelResult:
    mid = model.id if isinstance(model, ModelPreset) else str(model)
    llm = make_chat(model, **kwargs)
    started = time.perf_counter()
    messages: list[Any] = []
    if system:
        from langchain_core.messages import SystemMessage
        messages.append(SystemMessage(content=system))
    from langchain_core.messages import HumanMessage
    messages.append(HumanMessage(content=prompt))
    resp = llm.invoke(messages)
    elapsed = time.perf_counter() - started
    text = getattr(resp, "content", "") or ""
    approx_tokens = max(1, len(text) // 4)
    return PanelResult(
        model_id=mid,
        text=text,
        latency_sec=elapsed,
        tokens_per_sec=approx_tokens / elapsed if elapsed > 0 else 0.0,
    )


_FLOAT_RE = re.compile(r"-?\d+(?:\.\d+)?")


def _score_results(
    results: list[PanelResult],
    prompt: str,
    judge: Any,
    rubric: str,
) -> None:
    judge_llm = make_chat(judge, max_tokens=16, temperature=0.0)
    for r in results:
        if r.error or not r.text.strip():
            continue
        from langchain_core.messages import HumanMessage
        content = rubric.format(prompt=prompt, response=r.text)
        try:
            resp = judge_llm.invoke([HumanMessage(content=content)])
            raw = getattr(resp, "content", "") or ""
            m = _FLOAT_RE.search(raw)
            if m:
                r.score = max(0.0, min(10.0, float(m.group(0))))
        except Exception:
            # Judge failures shouldn't blow up the whole panel.
            pass
