"""GBNF grammar generator for pydantic schemas.

Used by ``extract()`` to enforce JSON output shape on llama.cpp backends. Only
handles the JSON-compatible subset of pydantic: str, int, float, bool, None,
list[T], dict[str, T], Optional[T], Union-of-leaves, BaseModel, and list[BaseModel].
"""
from __future__ import annotations

import json
from typing import Any


# A reusable base grammar that accepts standard JSON whitespace / primitives.
# We always define `ws` (optional whitespace) and `ws-required` but use `ws`
# almost everywhere — llama.cpp's GBNF tolerates optional whitespace fine.
_BASE = r"""
ws ::= [ \t\n]*
string ::= "\"" ( [^"\\\x00-\x1f] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}) )* "\""
number ::= "-"? ([0-9] | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
boolean ::= "true" | "false"
null ::= "null"
"""


def schema_to_gbnf(schema: dict[str, Any]) -> str:
    """Convert a JSON Schema (as produced by pydantic) to a GBNF grammar."""
    defs = schema.get("$defs") or schema.get("definitions") or {}
    rules: dict[str, str] = {}
    counter = {"i": 0}

    def _next_name(prefix: str = "rule") -> str:
        counter["i"] += 1
        return f"{prefix}-{counter['i']}"

    def _rule(subschema: dict[str, Any]) -> str:
        # Resolve refs
        ref = subschema.get("$ref")
        if ref:
            name = ref.rsplit("/", 1)[-1]
            safe = _sanitize(name)
            if safe not in rules:
                rules[safe] = "<pending>"  # placeholder prevents cycles
                rules[safe] = _rule(defs[name])
            return safe

        # Unions (anyOf / oneOf)
        if "anyOf" in subschema or "oneOf" in subschema:
            members = subschema.get("anyOf") or subschema.get("oneOf")
            parts = [_rule(m) for m in members]
            return "( " + " | ".join(parts) + " )"

        stype = subschema.get("type")
        if isinstance(stype, list):
            # ["string", "null"] etc.
            parts = [_rule({**subschema, "type": t}) for t in stype]
            return "( " + " | ".join(parts) + " )"

        if stype == "string":
            # enum support
            if "enum" in subschema:
                choices = " | ".join(_json_literal(v) for v in subschema["enum"])
                return "( " + choices + " )"
            return "string"
        if stype == "integer":
            return "number"
        if stype == "number":
            return "number"
        if stype == "boolean":
            return "boolean"
        if stype == "null":
            return "null"

        if stype == "array":
            items = subschema.get("items", {})
            item_rule = _rule(items) if items else "string"
            name = _next_name("arr")
            rules[name] = f'"[" ws ( {item_rule} ( ws "," ws {item_rule} )* )? ws "]"'
            return name

        if stype == "object" or "properties" in subschema:
            props = subschema.get("properties", {})
            required = set(subschema.get("required", []))
            name = _next_name("obj")

            if not props:
                # Arbitrary dict[str, Any] — keep it permissive
                rules[name] = '"{" ws ( string ws ":" ws _any ( ws "," ws string ws ":" ws _any )* )? ws "}"'
                rules["_any"] = "string | number | boolean | null"
                return name

            field_rules: list[str] = []
            for key, subs in props.items():
                field_rule = _rule(subs)
                field_pattern = f'"{_escape(key)}" ws ":" ws {field_rule}'
                field_rules.append((key, field_pattern, key in required))

            # Build a permutation-tolerant rule: required fields must appear,
            # others are optional. For simplicity we accept a fixed order
            # (required first by declaration) — most LLMs follow order anyway.
            parts: list[str] = []
            any_field = False
            for key, pat, is_req in field_rules:
                if is_req:
                    if any_field:
                        parts.append(' ws "," ws ')
                    parts.append(pat)
                    any_field = True
            optional_parts: list[str] = []
            for key, pat, is_req in field_rules:
                if not is_req:
                    optional_parts.append(f'( ws "," ws {pat} )?')
            middle = "".join(parts) + (" " + " ".join(optional_parts) if optional_parts else "")
            if not parts and optional_parts:
                # All fields optional
                joined = " | ".join(
                    pat for _, pat, _ in field_rules
                )
                middle = f'( {joined} ( ws "," ws ( {joined} ) )* )?'
            rules[name] = f'"{{" ws {middle} ws "}}"'
            return name

        # Fallback: permissive any
        rules["_any"] = "string | number | boolean | null"
        return "_any"

    root = _rule(schema)
    body = _BASE + "\n"
    for name, rule in rules.items():
        body += f"{name} ::= {rule}\n"
    body += f"root ::= {root}\n"
    return body


def _sanitize(name: str) -> str:
    return "".join(c if c.isalnum() else "-" for c in name).lower()


def _escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _json_literal(value: Any) -> str:
    return '"' + _escape(json.dumps(value)) + '"' if not isinstance(value, str) else '"\\"' + _escape(value) + '\\""'
