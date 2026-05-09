"""Form: pre-pull upstream images into the local registry.

Wraps `prime-registry-cache.sh` with optional filter pattern and
parallelism. Defaults run the full set sequentially.
"""
from __future__ import annotations

from typing import Iterable

from textual.widgets import Input

from . import ActionForm, FieldRow


class RegistryPrimeForm(ActionForm):

    def compose_fields(self) -> Iterable[FieldRow]:
        yield self.field(
            "Filter (image-name pattern)",
            Input(value=str(self.recalled.get("filter", "")),
                  placeholder="e.g. foundationbot/*", id="filter"),
        )
        yield self.field(
            "Parallelism",
            Input(value=str(self.recalled.get("parallelism", "")),
                  placeholder="default 1", id="parallelism"),
        )

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/prime-registry-cache.sh"]
        flt = (self.value("filter") or "").strip()
        if flt:
            cmd += ["--filter", flt]
        par = (self.value("parallelism") or "").strip()
        if par:
            cmd += ["--parallelism", par]
        return cmd
