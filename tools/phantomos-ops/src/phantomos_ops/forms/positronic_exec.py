"""Form: drop into a shell on positronic | locomotion.

Mirrors `positronic.sh exec <target>`. Most operators just want the
default bash; the form keeps the command-override field for the
power-user case.
"""
from __future__ import annotations

import shlex
from typing import Iterable

from textual.widgets import Input, RadioButton, RadioSet

from . import ActionForm, FieldRow


class PositronicExecForm(ActionForm):

    def compose_fields(self) -> Iterable[FieldRow]:
        target = self.recalled.get("target", "positronic")
        rs = RadioSet(id="target")
        # RadioSet children are added in compose; we set them here so
        # the recalled value is honored.
        rs._initial_target = target  # consumed in on_mount of base
        yield self.field("Target", rs)
        yield self.field(
            "Command (optional)",
            Input(value=str(self.recalled.get("cmd", "")),
                  placeholder="leave blank for interactive bash",
                  id="cmd"),
        )

    # RadioSet children must be mounted after compose; we override
    # on_mount to populate them.
    def on_mount(self) -> None:
        rs: RadioSet = self.field_widgets["target"]
        initial = getattr(rs, "_initial_target", "positronic")
        rs.mount(
            RadioButton("positronic", value=(initial == "positronic"),
                        id="t-positronic"),
            RadioButton("locomotion", value=(initial == "locomotion"),
                        id="t-locomotion"),
        )
        super().on_mount()

    def value(self, field_id: str):
        # RadioSet doesn't expose .value as the picked option directly
        # in older Textual; map ourselves.
        if field_id == "target":
            rs: RadioSet = self.field_widgets["target"]
            for child in rs.children:
                if isinstance(child, RadioButton) and child.value:
                    return "locomotion" if child.id == "t-locomotion" \
                        else "positronic"
            return "positronic"
        return super().value(field_id)

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/positronic.sh", "exec", self.value("target")]
        user_cmd = (self.value("cmd") or "").strip()
        if user_cmd:
            cmd += ["--", *shlex.split(user_cmd)]
        return cmd
