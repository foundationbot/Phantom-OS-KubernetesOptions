"""Fuzzy-search modal across all actions.

Bound to '/' on MainScreen. Operator types a few characters; matching
actions fall to the top, ranked by simple substring score. Picking
one returns the action id, MainScreen jumps to it (focus the action,
its group, and the detail pane).

Why not jellyfish or rapidfuzz: zero-deps fuzzy is good enough for
~25 short titles, and the operator wants snappy not clever.
"""
from __future__ import annotations

from typing import Iterable

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, ListItem, ListView, Static

from ..manifest import Action, Manifest


def _score(query: str, candidate: str) -> int:
    """Tiny ranking: 0 = no match; higher = better.

    Heuristics: exact substring beats subsequence match; earlier
    match position beats later; shorter title beats longer for
    same-quality match.
    """
    if not query:
        return 0
    q = query.lower()
    c = candidate.lower()
    if q in c:
        # Exact substring — score 1000 minus position penalty.
        return 1000 - c.index(q)
    # Subsequence: check chars in order.
    pos = 0
    matches = 0
    for ch in q:
        idx = c.find(ch, pos)
        if idx < 0:
            return 0
        matches += 1
        pos = idx + 1
    return 100 + matches


class SearchScreen(ModalScreen[str | None]):
    """Resolves to the picked action id, or None on cancel."""

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
    ]

    def __init__(self, manifest: Manifest):
        super().__init__()
        self.manifest = manifest

    def compose(self) -> ComposeResult:
        with Vertical(id="search-pane"):
            yield Static("Search actions", classes="title")
            self.input = Input(placeholder="type to filter…",
                               id="search-input")
            yield self.input
            self.list = ListView(id="search-results")
            yield self.list

    def on_mount(self) -> None:
        self._populate("")
        self.input.focus()

    def _populate(self, query: str) -> None:
        results = list(self._rank(query))
        self.list.clear()
        for action, _score_value in results[:25]:
            item = _ResultItem(action)
            self.list.append(item)
        if self.list.children:
            self.list.index = 0

    def _rank(self, query: str) -> Iterable[tuple[Action, int]]:
        if not query.strip():
            for a in self.manifest.actions:
                yield (a, 0)
            return
        scored = []
        for a in self.manifest.actions:
            s = max(_score(query, a.title),
                    _score(query, a.id),
                    _score(query, a.blurb))
            if s > 0:
                scored.append((a, s))
        scored.sort(key=lambda pair: pair[1], reverse=True)
        yield from scored

    @on(Input.Changed)
    def _on_input(self, event: Input.Changed) -> None:
        self._populate(event.value)

    @on(Input.Submitted)
    def _on_submitted(self, _event: Input.Submitted) -> None:
        if self.list.children and self.list.index is not None:
            item = self.list.children[self.list.index]
            if isinstance(item, _ResultItem):
                self.dismiss(item.action.id)

    @on(ListView.Selected)
    def _on_selected(self, event: ListView.Selected) -> None:
        if isinstance(event.item, _ResultItem):
            self.dismiss(event.item.action.id)

    def action_cancel(self) -> None:
        self.dismiss(None)


class _ResultItem(ListItem):
    def __init__(self, action: Action):
        super().__init__(Static(f"{action.title}    [dim]{action.id}[/dim]",
                                markup=True))
        self.action = action
