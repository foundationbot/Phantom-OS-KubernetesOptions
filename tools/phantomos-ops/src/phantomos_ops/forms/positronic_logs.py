"""Form: tail positronic-control logs.

Mirrors `positronic.sh logs` flags: -f follow, --previous read prior
crashed instance, --init load-models init container, --tail N.
"""
from __future__ import annotations

from typing import Iterable

from textual.widgets import Input, Switch

from . import ActionForm, FieldRow


class PositronicLogsForm(ActionForm):

    def compose_fields(self) -> Iterable[FieldRow]:
        yield self.field(
            "Follow",
            Switch(value=self.recalled.get("follow", True), id="follow"),
        )
        yield self.field(
            "Previous run",
            Switch(value=self.recalled.get("previous", False), id="previous"),
        )
        yield self.field(
            "Init container (load-models)",
            Switch(value=self.recalled.get("init", False), id="init"),
        )
        yield self.field(
            "Lines (tail)",
            Input(value=str(self.recalled.get("tail", "500")),
                  placeholder="500", id="tail"),
        )

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/positronic.sh", "logs"]
        if self.value("follow"):    cmd.append("-f")
        if self.value("previous"):  cmd.append("--previous")
        if self.value("init"):      cmd.append("--init")
        tail = (self.value("tail") or "").strip()
        if tail:
            cmd += ["--tail", tail]
        return cmd
