"""Tests for the subprocess runner.

Runner contract:
- run(cmd, on_line, cwd) returns a Job that streams output to on_line
  and resolves to an exit code (or a sentinel for cancellation /
  signal kill).
- cancel() escalates SIGINT → SIGTERM → SIGKILL with the documented
  timeouts, and never leaves zombies.
- Output streams in real-ish time (line-buffered, not buffered to
  EOF) — operators need to see logs while a long-running script
  is still working.
"""
from __future__ import annotations

import asyncio
import sys
import time

import pytest

from phantomos_ops.runner import Job, Outcome, run


@pytest.mark.asyncio
async def test_run_captures_stdout_lines():
    lines: list[str] = []
    job = run(["python3", "-c", "print('one'); print('two')"],
              on_line=lines.append)
    outcome = await job.wait()
    assert outcome.exit_code == 0
    assert outcome.cancelled is False
    assert lines == ["one", "two"]


@pytest.mark.asyncio
async def test_run_captures_stderr_lines():
    lines: list[str] = []
    job = run(
        ["python3", "-c", "import sys; sys.stderr.write('boom\\n')"],
        on_line=lines.append,
    )
    await job.wait()
    assert lines == ["boom"]


@pytest.mark.asyncio
async def test_exit_code_propagated():
    job = run(["python3", "-c", "import sys; sys.exit(7)"], on_line=lambda _: None)
    outcome = await job.wait()
    assert outcome.exit_code == 7


@pytest.mark.asyncio
async def test_streaming_is_line_at_a_time(tmp_path):
    """Lines must arrive incrementally, not all at EOF.
    Verifies by checking timestamps between lines."""
    script = tmp_path / "stream.py"
    script.write_text(
        "import sys, time\n"
        "for i in range(3):\n"
        "  print(f'line {i}', flush=True)\n"
        "  time.sleep(0.05)\n"
    )
    timestamps: list[float] = []

    def capture(_: str) -> None:
        timestamps.append(time.monotonic())

    job = run(["python3", str(script)], on_line=capture)
    await job.wait()
    # 3 lines, ~50ms apart → spread should be at least 80ms.
    assert len(timestamps) == 3
    assert timestamps[-1] - timestamps[0] > 0.08, (
        f"got {timestamps}; output looks buffered"
    )


@pytest.mark.asyncio
async def test_cancellation_sigint_path():
    """A child that handles SIGINT should exit promptly on cancel —
    no need to escalate to SIGTERM/SIGKILL."""
    job = run(
        ["python3", "-c",
         "import time, signal\n"
         "try:\n"
         "  while True: time.sleep(0.1)\n"
         "except KeyboardInterrupt:\n"
         "  raise SystemExit(130)\n"],
        on_line=lambda _: None,
    )
    # Let it actually start.
    await asyncio.sleep(0.1)
    job.cancel()
    outcome = await job.wait()
    assert outcome.cancelled is True
    # 130 is the conventional Ctrl-C exit code.
    assert outcome.exit_code in (130, -2)  # signal -2 == SIGINT


@pytest.mark.asyncio
async def test_cancellation_escalates_to_sigkill_on_uncooperative_child():
    """A child that ignores SIGINT and SIGTERM must still die — the
    runner's cascade ends in SIGKILL."""
    job = run(
        ["python3", "-c",
         "import signal, time\n"
         "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
         "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
         "while True: time.sleep(0.1)\n"],
        on_line=lambda _: None,
        # Tighten the cascade timeouts so the test stays fast.
        sigint_grace=0.2,
        sigterm_grace=0.2,
    )
    await asyncio.sleep(0.1)
    job.cancel()
    outcome = await job.wait()
    assert outcome.cancelled is True
    # SIGKILL exit shows up as -9 (negative signal) in returncode.
    assert outcome.exit_code == -9


@pytest.mark.asyncio
async def test_cwd_defaults_to_repo_root_for_bash_scripts():
    """Most actions invoke `bash scripts/foo.sh`. The runner must cd
    into the repo root so that relative path resolves regardless of
    where the operator launched the TUI from."""
    # We don't test the absolute path here (varies per host) — just
    # that explicit cwd is honored when supplied.
    lines: list[str] = []
    job = run(["pwd"], on_line=lines.append, cwd="/tmp")
    await job.wait()
    assert lines == ["/tmp"]


@pytest.mark.asyncio
async def test_command_not_found_does_not_crash():
    """A typo'd command must surface as an Outcome with cancelled=False
    and a non-zero exit code rather than raising FileNotFoundError.
    Otherwise a manifest typo crashes the run-screen instead of the
    operator seeing a useful error."""
    job = run(
        ["this-binary-does-not-exist-anywhere-2026"],
        on_line=lambda _: None,
    )
    outcome = await job.wait()
    assert outcome.cancelled is False
    assert outcome.exit_code != 0
    assert outcome.error  # human-readable error message attached


@pytest.mark.asyncio
async def test_outcome_duration_populated():
    job = run(["python3", "-c", "pass"], on_line=lambda _: None)
    outcome = await job.wait()
    assert outcome.duration_s >= 0
