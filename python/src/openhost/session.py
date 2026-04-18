"""Persistent, branchable chat sessions.

    with openhost.session("resume-work", model="qwen3-8b-gguf") as chat:
        chat.say("Evaluate this resume")
        branch = chat.branch("casual-tone")
        branch.say("Now make it conversational")

Turns are persisted to ``~/.openhost/sessions.db`` so chats survive restarts
and can be forked at any point.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Optional

from . import _session_db as db
from .chat import make_chat


@dataclass
class Turn:
    turn_id: int
    role: str           # "system" | "user" | "assistant"
    content: str
    created_at: int


@dataclass
class Branch:
    name: str
    head_turn_id: int


class ChatSession:
    """One branch of a persistent chat session. Use via :func:`session`."""

    def __init__(
        self,
        session_id: str,
        model_id: str,
        branch: str = "main",
        *,
        system: Optional[str] = None,
        chat_kwargs: Optional[dict[str, Any]] = None,
        memory: Any = None,
    ) -> None:
        self.session_id = session_id
        self.model_id = model_id
        self.branch_name = branch
        self._chat_kwargs = dict(chat_kwargs or {})
        self._system = system
        self._llm: Any = None
        self._memory = memory

    @property
    def llm(self) -> Any:
        if self._llm is None:
            self._llm = make_chat(self.model_id, **self._chat_kwargs)
        return self._llm

    # ---- Conversation ----

    def say(self, text: str) -> str:
        """Append a user turn, invoke the model, append the assistant reply, return it."""
        parent = db.head_turn_id(self.session_id, self.branch_name)

        # Memory hook: inject recall context as a system message for this turn only.
        extra_context = ""
        if self._memory is not None:
            try:
                extra_context = self._memory.recall(text)
            except Exception:
                extra_context = ""

        db.append_turn(
            session_id=self.session_id,
            branch=self.branch_name,
            role="user",
            content=text,
            parent_turn_id=parent,
        )

        messages = self._replay_messages()
        if extra_context:
            from langchain_core.messages import SystemMessage
            messages.insert(0, SystemMessage(content=f"Relevant memory:\n{extra_context}"))

        resp = self.llm.invoke(messages)
        reply = getattr(resp, "content", "") or ""

        new_parent = db.head_turn_id(self.session_id, self.branch_name)
        db.append_turn(
            session_id=self.session_id,
            branch=self.branch_name,
            role="assistant",
            content=reply,
            parent_turn_id=new_parent,
            stats_json=json.dumps({"model": self.model_id}),
        )

        # Memory hook: feed this exchange to the graph (non-blocking).
        if self._memory is not None:
            import sys as _sys
            try:
                self._memory.observe(f"User said: {text}\nAssistant replied: {reply}")
            except Exception as exc:  # noqa: BLE001
                # Surface extraction failures in dev; callers can wrap the
                # observe call themselves if they want full silencing.
                print(f"[openhost.session] memory.observe failed: {exc}", file=_sys.stderr)

        return reply

    def _replay_messages(self) -> list[Any]:
        from langchain_core.messages import HumanMessage, AIMessage, SystemMessage
        out: list[Any] = []
        if self._system:
            out.append(SystemMessage(content=self._system))
        for t in self.history:
            if t.role == "user":
                out.append(HumanMessage(content=t.content))
            elif t.role == "assistant":
                out.append(AIMessage(content=t.content))
            elif t.role == "system":
                out.append(SystemMessage(content=t.content))
        return out

    # ---- Navigation ----

    @property
    def history(self) -> list[Turn]:
        return [
            Turn(tid, role, content, ts)
            for (tid, role, content, ts) in db.list_turns(self.session_id, self.branch_name)
        ]

    def branches(self) -> list[Branch]:
        return [Branch(name=n, head_turn_id=h) for (n, h) in db.list_branches(self.session_id)]

    def branch(self, name: str) -> "ChatSession":
        """Fork from this branch's current head to a new named branch.

        The fork shares historical turns (the replay walks the *main* branch's
        turns by default); new turns appended to the child branch are stored
        under the new branch name so the parent stays untouched.
        """
        if name == self.branch_name:
            raise ValueError(f"branch name {name!r} matches current branch")
        # Nothing to do in the DB — the new branch is implicit until its first turn.
        # But copy the parent branch's history as the new branch's starting history.
        parent_turns = db.list_turns(self.session_id, self.branch_name)
        for tid, role, content, ts in parent_turns:
            db.append_turn(
                session_id=self.session_id,
                branch=name,
                role=role,
                content=content,
                parent_turn_id=None,  # simplified: linear branch
            )
        return ChatSession(
            session_id=self.session_id,
            model_id=self.model_id,
            branch=name,
            system=self._system,
            chat_kwargs=self._chat_kwargs,
            memory=self._memory,
        )

    # ---- Context manager ----

    def __enter__(self) -> "ChatSession":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        # Nothing to clean up — runners are managed by the global registry.
        return None


def session(
    session_id: str,
    *,
    model: Optional[str] = None,
    system: Optional[str] = None,
    branch: str = "main",
    memory: Any = None,
    **chat_kwargs: Any,
) -> ChatSession:
    """Open (or create) a persistent chat session.

    If the session already exists, ``model`` may be omitted — the stored model
    is reused. If it doesn't exist, ``model`` is required.
    """
    if db.session_exists(session_id):
        stored_model = db.get_model_id(session_id)
        if model and stored_model and model != stored_model:
            raise ValueError(
                f"session {session_id!r} was created with model {stored_model!r}; "
                f"pass model={stored_model!r} or a new session id."
            )
        model = stored_model  # type: ignore[assignment]
    else:
        if not model:
            raise ValueError(f"session {session_id!r} is new; `model=` is required.")
        db.ensure_session(session_id, model)

    assert model is not None
    return ChatSession(
        session_id=session_id,
        model_id=model,
        branch=branch,
        system=system,
        chat_kwargs=chat_kwargs,
        memory=memory,
    )
