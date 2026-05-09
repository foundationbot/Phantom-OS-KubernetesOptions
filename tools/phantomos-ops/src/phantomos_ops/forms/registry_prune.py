"""Form: list or remove tags from the local registry.

Wraps `prune-registry-tags.sh`. Default is dry-run; the operator
must explicitly opt out to actually delete.
"""
from __future__ import annotations

from typing import Iterable

from textual.widgets import Input, Switch

from . import ActionForm, FieldRow


class RegistryPruneForm(ActionForm):

    def compose_fields(self) -> Iterable[FieldRow]:
        yield self.field(
            "Pattern",
            Input(value=str(self.recalled.get("pattern", "")),
                  placeholder="e.g. mirror-test-*", id="pattern"),
        )
        yield self.field(
            "Dry run (preview only)",
            Switch(value=self.recalled.get("dry_run", True), id="dry_run"),
        )
        yield self.field(
            "Garbage-collect after",
            Switch(value=self.recalled.get("gc_after", False), id="gc_after"),
        )

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/prune-registry-tags.sh"]
        pattern = (self.value("pattern") or "").strip()
        if pattern:
            cmd.append(pattern)
        if self.value("dry_run"):
            cmd.append("--dry-run")
        if self.value("gc_after"):
            cmd.append("--gc-after")
        return cmd
