"""Form: send a raw opcode to the dma-recorder.

Wraps `dma-cmd raw 0x...`. Power-user only — the menu's
record_start / record_stop / ping cover the everyday cases.
"""
from __future__ import annotations

from typing import Iterable

from textual.widgets import Input, Switch

from . import ActionForm, FieldRow


class StreamsRawForm(ActionForm):

    def compose_fields(self) -> Iterable[FieldRow]:
        yield self.field(
            "Opcode (hex)",
            Input(value=str(self.recalled.get("opcode", "")),
                  placeholder="e.g. 0x0700", id="opcode"),
        )
        yield self.field(
            "Fire and forget (--no-wait)",
            Switch(value=self.recalled.get("no_wait", False), id="no_wait"),
        )
        yield self.field(
            "Timeout (seconds)",
            Input(value=str(self.recalled.get("timeout", "")),
                  placeholder="default 2", id="timeout"),
        )

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/dma-cmd.sh", "raw"]
        opcode = (self.value("opcode") or "").strip()
        if opcode:
            cmd.append(opcode)
        if self.value("no_wait"):
            cmd.append("--no-wait")
        timeout = (self.value("timeout") or "").strip()
        if timeout:
            cmd += ["--timeout", timeout]
        return cmd
