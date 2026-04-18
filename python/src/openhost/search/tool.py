"""LangChain BaseTool adapter that uses a `SearchProvider`."""
from __future__ import annotations

from typing import Any

from langchain_core.tools import BaseTool
from pydantic import Field, PrivateAttr

from .base import SearchProvider, format_results
from .duckduckgo import DuckDuckGoProvider


class OpenHostSearchTool(BaseTool):
    """LangChain tool: web search backed by any SearchProvider.

    Defaults to keyless DuckDuckGo. Pass `provider=...` to override.

    Example:
        >>> from openhost import OpenHostSearchTool
        >>> from openhost.search import TavilyProvider
        >>> tool = OpenHostSearchTool(provider=TavilyProvider("tvly-..."))
        >>> print(tool.invoke("who is the CEO of Anthropic"))
    """

    name: str = "openhost_web_search"
    description: str = (
        "Search the web for current information. Use for anything time-sensitive: "
        "news, recent facts, prices, versions, release dates. "
        "Input should be a concise search query. "
        "Returns titles, URLs, and snippets."
    )

    max_results: int = Field(default=5)

    _provider: SearchProvider = PrivateAttr()

    def __init__(self, provider: SearchProvider | None = None, **data: Any) -> None:
        super().__init__(**data)
        self._provider = provider or DuckDuckGoProvider()

    def _run(self, query: str, **kwargs: Any) -> str:
        results = self._provider.search(query, max_results=self.max_results)
        return format_results(query, results)

    async def _arun(self, query: str, **kwargs: Any) -> str:
        # Providers here are blocking; delegate for now.
        return self._run(query, **kwargs)
