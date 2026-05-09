"""Entry point for the `phantomos-ops` CLI.

For M1 the only mode is interactive. M5 will add `list`, `run <id>`,
and `--read-only`.
"""
from __future__ import annotations

import sys

from .app import OpsApp


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] in ("-h", "--help"):
        print(
            "Usage: phantomos-ops\n\n"
            "Interactive TUI launcher. See docs/ops-tui-user-guide.md."
        )
        return 0
    OpsApp().run()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
