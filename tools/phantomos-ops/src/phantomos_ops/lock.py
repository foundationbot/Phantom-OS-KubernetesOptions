"""Single-instance lock.

Per docs/ops-tui-user-guide.md: starting a second TUI on the same
host (e.g. when re-attaching tmux) opens read-only with a banner so
the two don't race on shared state (favorites, last-form-values).

Implementation: a fcntl.flock on a file under
~/.local/state/phantomos-ops/lock. Non-blocking — if the lock can't
be acquired, the second instance keeps going but in read-only mode.
The fd is held for the lifetime of the InstanceLock context manager.
"""
from __future__ import annotations

import fcntl
from pathlib import Path
from typing import IO


class InstanceLock:
    """Context manager — `with InstanceLock(path) as lock: ...`.

    ``lock.acquired`` is True when this process holds the lock,
    False when another process does. Either way, the context manager
    exits cleanly so the caller can react (banner, read-only mode)
    rather than crashing.
    """

    def __init__(self, path: Path):
        self.path = Path(path)
        self.acquired: bool = False
        self._fd: IO[bytes] | None = None

    def __enter__(self) -> "InstanceLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Open in append mode — never truncate, so a concurrent reader
        # doesn't see a half-written file. fcntl.flock is advisory,
        # so all phantomos-ops instances cooperate; nothing else
        # touches this file.
        try:
            self._fd = open(self.path, "ab")
            fcntl.flock(self._fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.acquired = True
        except (BlockingIOError, OSError):
            # Another holder, or the FS doesn't support flock — treat
            # as "not acquired" rather than blowing up the launch.
            self.acquired = False
            if self._fd is not None:
                self._fd.close()
                self._fd = None
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._fd is not None:
            try:
                fcntl.flock(self._fd.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            self._fd.close()
            self._fd = None
            self.acquired = False
