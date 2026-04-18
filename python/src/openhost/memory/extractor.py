"""LLM-backed entity/relation extraction for the memory graph.

Uses ``openhost.extract()`` so we get the same pydantic-validated retry loop
used elsewhere.
"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field

from ..extract import extract


class Triple(BaseModel):
    subject: str = Field(description="The entity the fact is about (a short noun phrase, e.g. 'Alice').")
    relation: str = Field(description="A short snake_case relation, e.g. 'works_at', 'is_sister_of', 'lives_in'.")
    object: Optional[str] = Field(default=None, description="The related entity when the fact is an edge, else null.")
    value_text: Optional[str] = Field(
        default=None,
        description="A literal value when the relation is an attribute (e.g. age, color). Null for entity-entity edges.",
    )
    confidence: float = Field(default=0.8, ge=0.0, le=1.0)


class EpisodeExtraction(BaseModel):
    triples: list[Triple]


_INSTRUCTION = """\
Extract factual triples from the user's text. Skip opinions and suggestions;
only encode facts the speaker commits to. Use snake_case for relations.
When you don't know, omit — do not invent. Return {"triples": []} if nothing
substantive is asserted.
"""


def extract_triples(text: str, model: str) -> list[Triple]:
    result = extract(
        text,
        schema=EpisodeExtraction,
        model=model,
        instruction=_INSTRUCTION,
        max_retries=2,
        temperature=0.1,
        max_tokens=3072,
    )
    return result.triples
