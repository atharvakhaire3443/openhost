"""Tavily search (API key required)."""
from __future__ import annotations

import httpx

from .base import SearchError, SearchResult


class TavilyProvider:
    kind = "tavily"

    def __init__(self, api_key: str) -> None:
        if not api_key:
            raise SearchError("Tavily requires an API key. Get one at tavily.com.")
        self.api_key = api_key

    def search(self, query: str, max_results: int = 5) -> list[SearchResult]:
        payload = {
            "api_key": self.api_key,
            "query": query,
            "max_results": max_results,
            "search_depth": "basic",
            "include_answer": False,
        }
        try:
            r = httpx.post("https://api.tavily.com/search", json=payload, timeout=10)
            r.raise_for_status()
        except httpx.HTTPError as exc:
            raise SearchError(f"Tavily request failed: {exc}") from exc

        data = r.json()
        results = data.get("results", [])
        return [
            SearchResult(
                title=x.get("title", ""),
                url=x.get("url", ""),
                snippet=x.get("content") or x.get("snippet", ""),
            )
            for x in results[:max_results]
        ]
