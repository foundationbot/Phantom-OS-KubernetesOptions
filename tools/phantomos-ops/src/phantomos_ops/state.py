"""Persisted operator state.

Stores favorites and last-used form values so the next launch
restores what the operator was doing. Lives at
~/.config/phantomos-ops/state.json — operators can delete it to
reset, the file is plain JSON.

Design rules:
- Atomic writes via temp-file rename so a crash mid-write doesn't
  corrupt the file.
- Corruption is recoverable: a malformed file is silently reset to
  defaults rather than crashing the app. The operator's worst case
  is "I lost my favorites once."
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


_DEFAULT_PATH = Path.home() / ".config" / "phantomos-ops" / "state.json"


@dataclass
class State:
    favorites: set[str] = field(default_factory=set)
    # action_id → field_id → value. Every form's compose_fields lays
    # out fields keyed by id; the form base class persists the last
    # entered values so the next time the operator opens the form
    # they don't have to re-type.
    form_values: dict[str, dict[str, Any]] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path | None = None) -> "State":
        p = Path(path) if path else _DEFAULT_PATH
        if not p.exists():
            return cls()
        try:
            data = json.loads(p.read_text())
            return cls(
                favorites=set(data.get("favorites", []) or []),
                form_values=dict(data.get("form_values", {}) or {}),
            )
        except (OSError, ValueError, json.JSONDecodeError):
            # Corrupted on disk — start clean rather than crash.
            return cls()

    def save(self, path: Path | None = None) -> None:
        p = Path(path) if path else _DEFAULT_PATH
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_text(json.dumps({
            "favorites": sorted(self.favorites),
            "form_values": self.form_values,
        }, indent=2))
        os.replace(tmp, p)

    def remember_form(self, action_id: str, values: dict[str, Any]) -> None:
        self.form_values[action_id] = dict(values)

    def recall_form(self, action_id: str) -> dict[str, Any]:
        return dict(self.form_values.get(action_id, {}))
