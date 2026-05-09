"""Entry point for the `phantomos-ops` CLI.

Modes:
    phantomos-ops                # interactive TUI
    phantomos-ops --read-only    # demo / over-the-shoulder safe — green only
    phantomos-ops list           # all action ids (M5 will add this)
    phantomos-ops run <id>       # one-shot launch (M5)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .app import OpsApp
from .lock import InstanceLock


_DEFAULT_LOCK_PATH = Path.home() / ".local" / "state" / "phantomos-ops" / "lock"


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="phantomos-ops",
        description="Textual TUI launcher for the phantomos fleet "
                    "operator scripts.",
    )
    p.add_argument(
        "--read-only", action="store_true",
        help="Hide yellow + red actions. For demos / over-the-shoulder.",
    )
    p.add_argument(
        "--no-lock", action="store_true",
        help="Skip the single-instance lock. Useful in CI/tests.",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    read_only = args.read_only
    if not args.no_lock:
        with InstanceLock(_DEFAULT_LOCK_PATH) as lock:
            if not lock.acquired:
                # Second instance — auto-degrade to read-only with
                # a stderr banner so the operator knows why some
                # actions are hidden.
                print(
                    "phantomos-ops: another instance is running on this "
                    "host; opening in read-only mode.",
                    file=sys.stderr,
                )
                read_only = True
            OpsApp(read_only=read_only).run()
    else:
        OpsApp(read_only=read_only).run()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
