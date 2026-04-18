"""Shared search types."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass
class SearchResult:
    title: str
    url: str
    snippet: str


class SearchError(RuntimeError):
    pass


class SearchProvider(Protocol):
    kind: str

    def search(self, query: str, max_results: int = 5) -> list[SearchResult]: ...


def format_results(query: str, results: list[SearchResult]) -> str:
    """Render a flat text block suitable for LLM context."""
    if not results:
        return f'No results for "{query}".'
    lines = [f'[Web search results for "{query}"]']
    for i, r in enumerate(results, 1):
        lines.append(f"{i}. {r.title}")
        lines.append(f"   {r.url}")
        if r.snippet:
            lines.append(f"   {r.snippet}")
    return "\n".join(lines)
