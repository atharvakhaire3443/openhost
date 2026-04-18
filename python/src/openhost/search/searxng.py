"""Self-hosted SearXNG search."""
from __future__ import annotations


import httpx

from .base import SearchError, SearchResult


class SearXNGProvider:
    kind = "searxng"

    def __init__(self, base_url: str) -> None:
        if not base_url:
            raise SearchError("SearXNG requires a base URL (e.g. http://localhost:8888).")
        self.base_url = base_url.rstrip("/")

    def search(self, query: str, max_results: int = 5) -> list[SearchResult]:
        url = f"{self.base_url}/search"
        params = {"q": query, "format": "json"}
        try:
            r = httpx.get(url, params=params, timeout=10)
            r.raise_for_status()
        except httpx.HTTPError as exc:
            raise SearchError(f"SearXNG request failed: {exc}") from exc

        results = r.json().get("results", [])
        return [
            SearchResult(
                title=x.get("title", ""),
                url=x.get("url", ""),
                snippet=x.get("content", ""),
            )
            for x in results[:max_results]
        ]
