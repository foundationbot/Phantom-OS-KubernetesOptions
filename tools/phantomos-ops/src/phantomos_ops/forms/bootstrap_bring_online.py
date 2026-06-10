"""Form: bring this machine online from scratch.

Wraps `bootstrap-robot.sh`. The full bootstrap takes no required args,
but a couple of host-level toggles are worth surfacing so operators
don't have to drop to a shell:

  --no-tailscale  pin the k0s API server to the LAN address instead of
                  the Tailscale one (robots brought up without Tailscale,
                  or on an isolated bench network).
  --keep-going    don't halt at the first failed phase (debugging a
                  partially-broken host).
"""
from __future__ import annotations

from typing import Iterable

from textual.widgets import Switch

from . import ActionForm, FieldRow


class BootstrapBringOnlineForm(ActionForm):

    def compose_fields(self) -> Iterable[FieldRow]:
        yield self.field(
            "No Tailscale (pin LAN API address)",
            Switch(value=self.recalled.get("no_tailscale", False),
                   id="no_tailscale"),
        )
        yield self.field(
            "Keep going past failed phases",
            Switch(value=self.recalled.get("keep_going", False),
                   id="keep_going"),
        )

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/bootstrap-robot.sh"]
        if self.value("no_tailscale"):
            cmd.append("--no-tailscale")
        if self.value("keep_going"):
            cmd.append("--keep-going")
        return cmd
