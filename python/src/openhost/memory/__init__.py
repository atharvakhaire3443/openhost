"""Temporal knowledge-graph memory for openhost.

Extracts entities and relations from text, stores them with temporal validity,
and supports hybrid graph + FTS recall.

Inspired by Zep's Graphiti but local-first, Python-only, and pydantic-validated.
"""
from .graph import Memory, Fact, memory

__all__ = ["Memory", "Fact", "memory"]
