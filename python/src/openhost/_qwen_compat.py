"""Qwen/MLX OpenAI-compat shim.

mlx_lm.server (and some llama.cpp builds) emit a non-standard ``reasoning``
field in Qwen's chat-completion responses. The OpenAI SDK doesn't know about it
and reads only ``message.content`` / ``delta.content``, which yields empty
strings during the Qwen chain-of-thought phase.

This module provides a custom ``httpx.Client`` that rewrites the raw response
body on the way back:

- For non-streaming: if ``choices[i].message.content`` is empty but
  ``choices[i].message.reasoning`` is present, promote the reasoning into
  content (wrapped with ``<think>…</think>``).
- For streaming SSE: do the same swap on each ``data: {...}`` line inside the
  ``delta`` object.

Plugging this into ``langchain_openai.ChatOpenAI(http_client=...)`` makes
Qwen-family local models Just Work with every OpenAI-compatible client.
"""
from __future__ import annotations

import json
from typing import Any

import httpx


class _ResponseRewriter(httpx.Client):
    """An ``httpx.Client`` that rewrites ``/v1/chat/completions`` responses so
    Qwen's ``reasoning`` field is folded into ``content``."""

    def send(self, request: httpx.Request, **kwargs) -> httpx.Response:  # type: ignore[override]
        response = super().send(request, **kwargs)
        if "/v1/chat/completions" not in str(request.url):
            return response

        # Read the body eagerly so we can rewrite it. httpx supports
        # re-setting _content for a not-yet-consumed response.
        content_type = response.headers.get("content-type", "")

        # Streaming SSE responses
        if "text/event-stream" in content_type:
            original = response.read()
            rewritten = _rewrite_sse_bytes(original)
            response._content = rewritten  # type: ignore[attr-defined]
            response.headers["content-length"] = str(len(rewritten))
            return response

        # Regular JSON responses
        if "application/json" in content_type:
            try:
                original = response.read()
                data = json.loads(original)
            except Exception:
                return response
            changed = _rewrite_completion_dict(data)
            if changed:
                rewritten = json.dumps(data).encode("utf-8")
                response._content = rewritten  # type: ignore[attr-defined]
                response.headers["content-length"] = str(len(rewritten))
        return response


def build_http_client(timeout: float = 600.0) -> httpx.Client:
    """Return an httpx client with Qwen reasoning→content rewriting enabled."""
    return _ResponseRewriter(timeout=timeout)


# --- helpers ---------------------------------------------------------------


def _rewrite_completion_dict(data: dict[str, Any]) -> bool:
    """Mutate a non-streaming chat.completion dict in place.

    Returns True if anything changed."""
    changed = False
    choices = data.get("choices")
    if not isinstance(choices, list):
        return False
    for choice in choices:
        msg = choice.get("message") if isinstance(choice, dict) else None
        if not isinstance(msg, dict):
            continue
        content = msg.get("content") or ""
        reasoning = msg.get("reasoning")
        if reasoning and not content:
            msg["content"] = f"<think>{reasoning}</think>"
            changed = True
        elif reasoning and content:
            msg["content"] = f"<think>{reasoning}</think>\n\n{content}"
            changed = True
    return changed


def _rewrite_sse_bytes(body: bytes) -> bytes:
    out_lines: list[bytes] = []
    seen_reasoning = False
    for raw_line in body.split(b"\n"):
        if not raw_line.startswith(b"data:"):
            out_lines.append(raw_line)
            continue
        payload = raw_line[5:].strip()
        if payload in (b"", b"[DONE]"):
            out_lines.append(raw_line)
            continue
        try:
            evt = json.loads(payload)
        except Exception:
            out_lines.append(raw_line)
            continue
        mutated = False
        for choice in evt.get("choices", []) or []:
            delta = choice.get("delta") or {}
            reasoning = delta.get("reasoning")
            content = delta.get("content") or ""
            if reasoning:
                if not seen_reasoning:
                    delta["content"] = "<think>" + reasoning + content
                    seen_reasoning = True
                else:
                    delta["content"] = reasoning + content
                delta.pop("reasoning", None)
                choice["delta"] = delta
                mutated = True
            elif seen_reasoning and not delta.get("content_patched"):
                # First non-reasoning delta after a reasoning run: close the tag.
                delta["content"] = "</think>" + (delta.get("content") or "")
                delta["content_patched"] = True
                seen_reasoning = False
                choice["delta"] = delta
                mutated = True
        if mutated:
            out_lines.append(b"data: " + json.dumps(evt).encode("utf-8"))
        else:
            out_lines.append(raw_line)
    return b"\n".join(out_lines)
