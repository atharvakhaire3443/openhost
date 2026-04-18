"""Web search providers and LangChain tool adapter."""
from .base import SearchProvider, SearchResult, SearchError
from .duckduckgo import DuckDuckGoProvider
from .tavily import TavilyProvider
from .brave import BraveProvider
from .searxng import SearXNGProvider
from .tool import OpenHostSearchTool

__all__ = [
    "SearchProvider",
    "SearchResult",
    "SearchError",
    "DuckDuckGoProvider",
    "TavilyProvider",
    "BraveProvider",
    "SearXNGProvider",
    "OpenHostSearchTool",
]
