"""Pydantic-validated structured extraction from unstructured text.

    from pydantic import BaseModel
    from openhost import extract

    class Person(BaseModel):
        name: str
        age: int

    people = extract("Alice is 30, Bob is 25", schema=list[Person])

Strategy:
  1. Prompt the model with the pydantic JSON schema and require JSON-only output
     (``response_format={"type": "json_object"}`` is honored by both llama.cpp
     and mlx_lm.server; we don't require tool-calling support).
  2. Parse the response as JSON, validate against the pydantic schema.
  3. On failure, send the validation error back as a correction message and
     retry up to ``max_retries`` times.

A future version will add llama.cpp GBNF grammar enforcement via the module
``openhost._grammar`` for guaranteed valid output on the first pass.
"""
from __future__ import annotations

import json
import re
from typing import Any, Type, TypeVar, get_args, get_origin

from pydantic import TypeAdapter, ValidationError

from .chat import make_chat

T = TypeVar("T")


class ExtractionError(RuntimeError):
    """Raised when the model could not produce valid output within retries."""


def extract(
    text: str,
    *,
    schema: Type[T] | Any,
    model: str,
    instruction: str | None = None,
    max_retries: int = 3,
    temperature: float = 0.2,
    max_tokens: int = 2048,
    timeout: float = 600,
) -> T:
    """Extract structured data from ``text`` matching ``schema``.

    Args:
        text: source text to extract from.
        schema: a pydantic ``BaseModel`` subclass, a typing construct like
            ``list[MyModel]``, or any type understandable by pydantic's ``TypeAdapter``.
        model: the openhost model id to run the extraction on.
        instruction: optional extra guidance (appended after the default).
        max_retries: validation-failure retry budget.

    Returns:
        An instance of ``schema`` (or the typed container).
    """
    adapter = TypeAdapter(schema)
    try:
        json_schema = adapter.json_schema()
    except Exception as exc:  # noqa: BLE001
        raise ExtractionError(f"Cannot build JSON schema for {schema!r}: {exc}") from exc

    llm = make_chat(
        model,
        max_tokens=max_tokens,
        temperature=temperature,
        timeout=timeout,
    )

    from langchain_core.messages import HumanMessage, SystemMessage, AIMessage

    system = (
        "You are an information-extraction system.\n"
        "Extract the requested data from the user's text.\n"
        "Output a SINGLE JSON value that validates against the schema below. "
        "Do not include any prose, markdown fences, or commentary — ONLY the JSON.\n\n"
        f"Schema (JSON Schema draft-7):\n{json.dumps(json_schema, indent=2)}"
    )
    if instruction:
        system += f"\n\nAdditional instructions:\n{instruction}"

    # Qwen3-family models interpret `/no_think` as "skip chain-of-thought" when
    # it trails the user message. Harmless for non-Qwen models.
    user_text = f"{text}\n/no_think"

    messages: list[Any] = [SystemMessage(content=system), HumanMessage(content=user_text)]

    last_error: Exception | None = None
    last_raw: str = ""
    for attempt in range(max_retries + 1):
        resp = llm.invoke(messages)
        raw = getattr(resp, "content", "") or ""
        last_raw = raw
        payload = _extract_json_payload(raw)
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError as exc:
            last_error = exc
            if attempt >= max_retries:
                break
            messages.extend([
                AIMessage(content=raw),
                HumanMessage(content=(
                    f"That was not valid JSON. Parser said: {exc.msg} at char {exc.pos}.\n"
                    "Return ONLY a valid JSON value matching the schema. Try again."
                )),
            ])
            continue

        try:
            return adapter.validate_python(obj)
        except ValidationError as exc:
            last_error = exc
            if attempt >= max_retries:
                break
            messages.extend([
                AIMessage(content=raw),
                HumanMessage(content=(
                    "The JSON was valid but failed schema validation. Errors:\n"
                    + _format_validation_errors(exc)
                    + "\nFix these and return corrected JSON only."
                )),
            ])

    raise ExtractionError(
        f"Could not extract valid {_describe_schema(schema)} after {max_retries + 1} attempts. "
        f"Last error: {last_error}. Last raw output (first 300 chars): {last_raw[:300]!r}"
    )


# --------------- helpers ---------------


_FENCE_RE = re.compile(r"```(?:json)?\s*(\{[\s\S]*?\}|\[[\s\S]*?\])\s*```", re.IGNORECASE)


def _extract_json_payload(raw: str) -> str:
    """Strip code fences, <think> blocks, and surrounding prose."""
    # Drop <think>...</think>
    raw = re.sub(r"<think>[\s\S]*?</think>", "", raw, flags=re.IGNORECASE).strip()
    # Prefer content inside a fenced block
    m = _FENCE_RE.search(raw)
    if m:
        return m.group(1)
    # Otherwise, grab the first balanced JSON object or array we find.
    start = _first_json_start(raw)
    if start == -1:
        return raw
    return _extract_balanced(raw, start)


def _first_json_start(s: str) -> int:
    for i, ch in enumerate(s):
        if ch in "{[":
            return i
    return -1


def _extract_balanced(s: str, start: int) -> str:
    stack: list[str] = []
    in_string = False
    escape = False
    for i in range(start, len(s)):
        ch = s[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch in "{[":
            stack.append(ch)
        elif ch in "}]":
            if not stack:
                return s[start:i + 1]
            stack.pop()
            if not stack:
                return s[start:i + 1]
    return s[start:]


def _format_validation_errors(exc: ValidationError) -> str:
    lines: list[str] = []
    for err in exc.errors():
        loc = ".".join(str(p) for p in err.get("loc", ()))
        lines.append(f"- {loc}: {err.get('msg')}")
    return "\n".join(lines) or str(exc)


def _describe_schema(schema: Any) -> str:
    origin = get_origin(schema)
    if origin in (list, tuple, set):
        args = get_args(schema)
        inner = args[0].__name__ if args and isinstance(args[0], type) else "T"
        return f"{origin.__name__}[{inner}]"
    if isinstance(schema, type):
        return schema.__name__
    return repr(schema)
