"""Subprocess runner.

Spawns a child in its own process group so the cancellation cascade
(SIGINT → SIGTERM → SIGKILL) hits the whole tree, not just the top
shell. Streams stdout/stderr line-by-line through a callback so the
UI can update as the script runs, not at EOF.

Why a custom runner instead of asyncio.subprocess directly:
- We need a *combined* stdout+stderr stream so the operator sees both
  in one log pane, in their actual interleaving order.
- We need cancellation that actually escalates — the default
  asyncio cancellation just raises CancelledError, which leaves the
  child running.
- We want command-not-found and other startup failures to surface as
  an Outcome rather than an exception, so the run-screen renders a
  banner instead of crashing.

The runner has no Textual dependency and is fully unit-testable.
"""
from __future__ import annotations

import asyncio
import os
import signal
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

LineCallback = Callable[[str], None]

# Default cancellation cascade timeouts. Tests override these to keep
# the suite fast — operators rarely want them shorter than this.
_DEFAULT_SIGINT_GRACE = 3.0
_DEFAULT_SIGTERM_GRACE = 5.0


@dataclass(frozen=True)
class Outcome:
    """Result of a finished Job. ``error`` is populated only when the
    runner couldn't even start the child (e.g. command not found).
    ``cancelled`` is True when cancel() was called, regardless of
    which signal in the cascade actually killed the child."""
    exit_code: int
    cancelled: bool
    duration_s: float
    error: str = ""


@dataclass
class Job:
    """Handle to a running subprocess.

    Construct via :func:`run`. Callers wait via ``await job.wait()``
    and cancel via ``job.cancel()``. Mutating any other attribute is
    not part of the public contract.
    """
    cmd: tuple[str, ...]
    cwd: str
    on_line: LineCallback
    sigint_grace: float
    sigterm_grace: float

    _proc: asyncio.subprocess.Process | None = None
    _start_t: float = 0.0
    _outcome: Outcome | None = None
    _cancel_requested: bool = False
    _start_task: asyncio.Task | None = None
    _drainer_task: asyncio.Task | None = None
    _waiter_task: asyncio.Task | None = None

    async def _start(self) -> None:
        self._start_t = time.monotonic()
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *self.cmd,
                cwd=self.cwd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                # Own process group so the cancel cascade hits the
                # whole tree (e.g. bash + the script bash spawned).
                start_new_session=True,
            )
        except (FileNotFoundError, NotADirectoryError, PermissionError) as exc:
            self._outcome = Outcome(
                exit_code=127,
                cancelled=False,
                duration_s=0.0,
                error=f"cannot start {self.cmd[0]!r}: {exc}",
            )
            return

        self._drainer_task = asyncio.create_task(self._drain_stdout())
        self._waiter_task = asyncio.create_task(self._wait_for_exit())

    async def _drain_stdout(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        async for raw in self._proc.stdout:
            line = raw.decode(errors="replace").rstrip("\n")
            try:
                self.on_line(line)
            except Exception:  # pragma: no cover — callback faults
                # The runner must never crash because the UI's line
                # handler raised. Swallow + drop; the worst case is
                # the operator missing one log line.
                pass

    async def _wait_for_exit(self) -> None:
        assert self._proc is not None
        rc = await self._proc.wait()
        if self._drainer_task is not None:
            await self._drainer_task
        self._outcome = Outcome(
            exit_code=rc,
            cancelled=self._cancel_requested,
            duration_s=time.monotonic() - self._start_t,
        )

    async def wait(self) -> Outcome:
        """Block until the child exits. Returns an Outcome — never
        raises, even when the child failed to start or was cancelled.
        """
        # Make sure _start has run before we look at the post-start
        # state. run() schedules _start eagerly so the caller gets a
        # Job back synchronously, but the spawn itself is still async.
        if self._start_task is not None:
            await self._start_task
        if self._outcome is not None:
            # _start hit a startup error and short-circuited; or this
            # is a second wait() call after the run already completed.
            return self._outcome
        if self._waiter_task is not None:
            await self._waiter_task
        assert self._outcome is not None  # _wait_for_exit always sets it
        return self._outcome

    def cancel(self) -> None:
        """Request graceful cancellation. Returns immediately — the
        cascade runs in the background. Wait() will resolve with
        cancelled=True once the child is gone."""
        if self._proc is None or self._outcome is not None:
            return
        if self._cancel_requested:
            return  # cascade already running
        self._cancel_requested = True
        asyncio.create_task(self._cancel_cascade())

    async def _cancel_cascade(self) -> None:
        """SIGINT → wait sigint_grace → SIGTERM → wait sigterm_grace
        → SIGKILL. Each step targets the entire process group so a
        bash wrapper passing the signal along to its child works as
        expected."""
        assert self._proc is not None
        pid = self._proc.pid
        try:
            pgid = os.getpgid(pid)
        except ProcessLookupError:
            return  # already gone

        for sig, grace in (
            (signal.SIGINT, self.sigint_grace),
            (signal.SIGTERM, self.sigterm_grace),
            (signal.SIGKILL, 0.0),
        ):
            try:
                os.killpg(pgid, sig)
            except ProcessLookupError:
                return  # gone between checks
            try:
                await asyncio.wait_for(self._proc.wait(), timeout=grace)
                return  # exited within the grace window
            except asyncio.TimeoutError:
                continue  # escalate to next signal


def run(
    cmd: list[str] | tuple[str, ...],
    on_line: LineCallback,
    cwd: str | Path | None = None,
    sigint_grace: float = _DEFAULT_SIGINT_GRACE,
    sigterm_grace: float = _DEFAULT_SIGTERM_GRACE,
) -> Job:
    """Spawn a subprocess and return a Job.

    cmd is the argv list — never a shell string (matches the
    manifest's command field).

    cwd defaults to the current working directory if None. Most
    callers pass the repo root so that relative ``scripts/foo.sh``
    paths resolve consistently regardless of where the operator
    launched the TUI from.
    """
    job = Job(
        cmd=tuple(cmd),
        cwd=str(cwd) if cwd is not None else os.getcwd(),
        on_line=on_line,
        sigint_grace=sigint_grace,
        sigterm_grace=sigterm_grace,
    )
    # Schedule the spawn so callers get a Job back synchronously. The
    # spawn itself is async (asyncio.create_subprocess_exec); wait()
    # awaits this task before returning, so callers never observe a
    # half-initialised Job.
    job._start_task = asyncio.create_task(job._start())
    return job
