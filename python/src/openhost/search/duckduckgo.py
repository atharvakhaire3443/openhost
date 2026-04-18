"""Keyless DuckDuckGo HTML search (best-effort parser)."""
from __future__ import annotations

import re
import urllib.parse
from html import unescape

import httpx

from .base import SearchError, SearchResult


_LINK_RE = re.compile(
    r'<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
    re.IGNORECASE,
)
_SNIPPET_RE = re.compile(
    r'<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</a>',
    re.IGNORECASE,
)
_TAG_RE = re.compile(r"<[^>]+>")


class DuckDuckGoProvider:
    kind = "duckduckgo"

    def search(self, query: str, max_results: int = 5) -> list[SearchResult]:
        url = f"https://html.duckduckgo.com/html/?q={urllib.parse.quote_plus(query)}"
        headers = {
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
                          "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                          "Version/17.0 Safari/605.1.15",
        }
        try:
            r = httpx.get(url, headers=headers, timeout=8, follow_redirects=True)
            r.raise_for_status()
        except httpx.HTTPError as exc:
            raise SearchError(f"DuckDuckGo request failed: {exc}") from exc

        html = r.text
        links = _LINK_RE.findall(html)
        snippets = [_clean(m) for m in _SNIPPET_RE.findall(html)]

        out: list[SearchResult] = []
        for i, (raw_url, raw_title) in enumerate(links[:max_results]):
            title = _clean(raw_title)
            url_final = _resolve_ddg_redirect(raw_url)
            snippet = snippets[i] if i < len(snippets) else ""
            out.append(SearchResult(title=title, url=url_final, snippet=snippet))
        if not out:
            raise SearchError("No results parsed from DuckDuckGo HTML (layout may have changed).")
        return out


def _clean(s: str) -> str:
    s = _TAG_RE.sub("", s)
    return unescape(s).strip()


def _resolve_ddg_redirect(href: str) -> str:
    prefix = "//duckduckgo.com/l/?uddg="
    if prefix in href:
        tail = href.split(prefix, 1)[1]
        end = tail.find("&")
        if end != -1:
            tail = tail[:end]
        return urllib.parse.unquote(tail)
    if href.startswith("//"):
        return "https:" + href
    return href
