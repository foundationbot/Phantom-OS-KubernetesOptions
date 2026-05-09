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
import json
import os
import signal
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

LineCallback = Callable[[str], None]
EventCallback = Callable[[dict[str, Any]], None]

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

    Bridge mode: when ``on_event`` is set, the child is given an
    extra writable fd 3 plus a writable stdin pipe. Lines on fd 3 are
    parsed as JSON events and dispatched to ``on_event``; the runner's
    ``respond(line)`` method writes a reply to the child's stdin.
    Used by the TUI to translate scripts' ``op_ask`` calls into native
    Input modals and feed the answer back. See scripts/lib/ops-prompt.sh.
    """
    cmd: tuple[str, ...]
    cwd: str
    on_line: LineCallback
    sigint_grace: float
    sigterm_grace: float
    on_event: EventCallback | None = None

    _proc: asyncio.subprocess.Process | None = None
    _start_t: float = 0.0
    _outcome: Outcome | None = None
    _cancel_requested: bool = False
    _start_task: asyncio.Task | None = None
    _drainer_task: asyncio.Task | None = None
    _event_task: asyncio.Task | None = None
    _waiter_task: asyncio.Task | None = None
    _event_read_fd: int | None = None    # parent end of the bridge pipe

    async def _start(self) -> None:
        self._start_t = time.monotonic()

        # Bridge pipe: parent reads JSON events from fd r; child writes
        # to fd 3 specifically (the helper probes via `printf '' >&3`).
        #
        # asyncio.create_subprocess_exec silently drops preexec_fn, so
        # we can't dup2 in Python after fork. Instead, when bridge mode
        # is active, we wrap the command in `bash -c 'exec 3>&N; ...'`
        # which remaps the inherited fd N to fd 3 at the shell level
        # before the real script runs. Cost: one extra bash process
        # that immediately exec()s away (so ps still shows the script,
        # not the bash wrapper).
        #
        # Stdin must be a pipe (not /dev/null) so respond() can feed
        # operator replies back to the script's `read`.
        import shlex
        pass_fds: tuple[int, ...] = ()
        stdin_target: Any = asyncio.subprocess.DEVNULL
        cmd_to_run = list(self.cmd)
        if self.on_event is not None:
            r, w = os.pipe()
            self._event_read_fd = r
            pass_fds = (w,)
            stdin_target = asyncio.subprocess.PIPE
            inner = " ".join(shlex.quote(s) for s in self.cmd)
            cmd_to_run = [
                "bash", "-c",
                f"exec 3>&{w} {w}>&-; exec {inner}",
            ]

        try:
            self._proc = await asyncio.create_subprocess_exec(
                *cmd_to_run,
                cwd=self.cwd,
                stdin=stdin_target,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                pass_fds=pass_fds,
                # Own process group so the cancel cascade hits the
                # whole tree (e.g. bash + the script bash spawned).
                start_new_session=True,
            )
        except (FileNotFoundError, NotADirectoryError, PermissionError) as exc:
            if self._event_read_fd is not None:
                os.close(self._event_read_fd)
                self._event_read_fd = None
            if pass_fds:
                for fd in pass_fds:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            self._outcome = Outcome(
                exit_code=127,
                cancelled=False,
                duration_s=0.0,
                error=f"cannot start {self.cmd[0]!r}: {exc}",
            )
            return

        # The child holds its own dup of the bridge write end. Close
        # the parent's copy; otherwise the pipe never reaches EOF
        # when the child exits because we'd still hold a write end.
        for fd in pass_fds:
            try:
                os.close(fd)
            except OSError:
                pass

        self._drainer_task = asyncio.create_task(self._drain_stdout())
        if self.on_event is not None and self._event_read_fd is not None:
            self._event_task = asyncio.create_task(
                self._drain_events(self._event_read_fd)
            )
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

    async def _drain_events(self, fd: int) -> None:
        """Read JSON-per-line bridge events from the child's fd 3.

        Uses asyncio's event-loop reader so we don't tie up a thread.
        Each line is parsed as JSON; malformed lines (script writing
        garbage to fd 3 by accident) are silently dropped — the
        runner must never crash on protocol noise.
        """
        loop = asyncio.get_running_loop()
        # Open in binary, non-blocking, and bridge through asyncio's
        # StreamReader so the iteration is line-buffered.
        reader = asyncio.StreamReader()
        protocol = asyncio.StreamReaderProtocol(reader)
        # connect_read_pipe takes a file-like object; wrap the fd.
        pipe = os.fdopen(fd, "rb", buffering=0, closefd=True)
        await loop.connect_read_pipe(lambda: protocol, pipe)
        try:
            while True:
                raw = await reader.readline()
                if not raw:
                    return  # child closed the pipe (usually exit)
                line = raw.decode(errors="replace").rstrip("\n")
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict):
                    continue
                try:
                    if self.on_event is not None:
                        self.on_event(event)
                except Exception:  # pragma: no cover
                    pass
        finally:
            self._event_read_fd = None

    def respond(self, reply: str) -> None:
        """Feed a single line to the child's stdin (bridge replies).

        Used by the TUI's ask/confirm modals — operator types an
        answer, modal calls respond("hwthor01"), the script's
        `read` returns. No-op when the child has no stdin pipe.
        """
        if self._proc is None or self._proc.stdin is None:
            return
        try:
            self._proc.stdin.write(reply.encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    async def _wait_for_exit(self) -> None:
        assert self._proc is not None
        rc = await self._proc.wait()
        if self._drainer_task is not None:
            await self._drainer_task
        if self._event_task is not None:
            try:
                await self._event_task
            except Exception:  # pragma: no cover
                pass
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
    on_event: EventCallback | None = None,
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
        on_event=on_event,
    )
    # Schedule the spawn so callers get a Job back synchronously. The
    # spawn itself is async (asyncio.create_subprocess_exec); wait()
    # awaits this task before returning, so callers never observe a
    # half-initialised Job.
    job._start_task = asyncio.create_task(job._start())
    return job
