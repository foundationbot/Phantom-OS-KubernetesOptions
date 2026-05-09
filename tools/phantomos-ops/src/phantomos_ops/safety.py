"""Safety classification.

Mirrors the decision tree in docs/ops-tui-dev-guide.md. The renderer
consults this to pick the glyph + colour + whether to show a confirm
modal. Kept as a tiny pure-Python module so it's testable without
Textual and reusable from `phantomos-ops list`.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

SafetyClass = Literal["green", "yellow", "red"]


@dataclass(frozen=True)
class SafetyStyle:
    glyph: str          # printed in the action-list left margin
    css_class: str      # CSS modifier — paired with .glyph
    word: str           # printed in the detail pane ("Read-only", etc.)


_STYLES: dict[SafetyClass, SafetyStyle] = {
    "green":  SafetyStyle("●", "green",  "Read-only"),
    "yellow": SafetyStyle("●", "yellow", "Changes state · reversible"),
    "red":    SafetyStyle("⚠", "red",    "Destructive · confirm required"),
}


def style(safety: SafetyClass) -> SafetyStyle:
    """Return the rendering style for a safety class.

    Falls back to red on unknown input — fail loud for malformed
    manifests rather than hide a missing classification behind a
    benign-looking green dot.
    """
    return _STYLES.get(safety, _STYLES["red"])


def needs_confirm(safety: SafetyClass) -> bool:
    """Red actions always need explicit confirmation. Yellow and green
    fire on Enter."""
    return safety == "red"
