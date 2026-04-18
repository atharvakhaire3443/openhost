"""Brave Search (API key required)."""
from __future__ import annotations

import re

import httpx

from .base import SearchError, SearchResult


_TAG_RE = re.compile(r"<[^>]+>")


class BraveProvider:
    kind = "brave"

    def __init__(self, api_key: str) -> None:
        if not api_key:
            raise SearchError("Brave requires an API key. Get one at brave.com/search/api.")
        self.api_key = api_key

    def search(self, query: str, max_results: int = 5) -> list[SearchResult]:
        headers = {
            "X-Subscription-Token": self.api_key,
            "Accept": "application/json",
        }
        params = {"q": query, "count": max_results}
        try:
            r = httpx.get(
                "https://api.search.brave.com/res/v1/web/search",
                headers=headers,
                params=params,
                timeout=10,
            )
            r.raise_for_status()
        except httpx.HTTPError as exc:
            raise SearchError(f"Brave request failed: {exc}") from exc

        data = r.json()
        web = data.get("web") or {}
        results = web.get("results", [])
        return [
            SearchResult(
                title=_strip(x.get("title", "")),
                url=x.get("url", ""),
                snippet=_strip(x.get("description", "")),
            )
            for x in results[:max_results]
        ]


def _strip(s: str) -> str:
    return _TAG_RE.sub("", s or "").strip()
