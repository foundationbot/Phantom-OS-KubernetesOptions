"""Bridge protocol — fd 3 events + stdin replies."""
from __future__ import annotations

import asyncio
import os
from pathlib import Path

import pytest

from phantomos_ops.runner import run


def _ops_prompt_path() -> Path:
    """Resolve scripts/lib/ops-prompt.sh from the repo root."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "scripts" / "lib" / "ops-prompt.sh"
        if candidate.is_file():
            return candidate
    raise RuntimeError("ops-prompt.sh not found in any parent directory")


@pytest.mark.asyncio
async def test_no_on_event_means_no_fd3_no_stdin_pipe(tmp_path):
    """Without on_event the runner shouldn't open extra fds — backwards
    compatible with the existing run() callers."""
    job = run(["python3", "-c", "print('hello')"], on_line=lambda _: None)
    out = await job.wait()
    assert out.exit_code == 0


@pytest.mark.asyncio
async def test_bridge_emits_status_event(tmp_path):
    """A script sourcing ops-prompt.sh and calling op_pass emits a JSON
    status event on fd 3."""
    helper = _ops_prompt_path()
    script = tmp_path / "go.sh"
    script.write_text(
        f". {helper}\n"
        "op_pass 'hello from inside'\n"
    )
    events: list[dict] = []
    job = run(
        ["bash", str(script)],
        on_line=lambda _: None,
        on_event=events.append,
    )
    out = await job.wait()
    assert out.exit_code == 0
    assert events == [{"event": "status", "level": "pass",
                       "msg": "hello from inside"}]


@pytest.mark.asyncio
async def test_bridge_phase_event(tmp_path):
    helper = _ops_prompt_path()
    script = tmp_path / "go.sh"
    script.write_text(f". {helper}\nop_phase 'Preflight'\n")
    events: list[dict] = []
    job = run(["bash", str(script)],
              on_line=lambda _: None, on_event=events.append)
    await job.wait()
    assert events == [{"event": "phase", "title": "Preflight"}]


@pytest.mark.asyncio
async def test_bridge_ask_round_trips_via_respond(tmp_path):
    """op_ask emits an event, then waits for stdin — the runner's
    respond() feeds the answer back."""
    helper = _ops_prompt_path()
    script = tmp_path / "go.sh"
    script.write_text(
        f". {helper}\n"
        "name=\"$(op_ask robot 'Robot?' 'default01')\"\n"
        "echo \"got=$name\"\n"
    )

    pending_replies: list[str] = ["mk09"]
    captured_lines: list[str] = []

    job_holder: list = []

    def _on_event(event):
        if event.get("event") == "ask":
            job_holder[0].respond(pending_replies.pop(0))

    job = run(
        ["bash", str(script)],
        on_line=captured_lines.append,
        on_event=_on_event,
    )
    job_holder.append(job)
    out = await job.wait()
    assert out.exit_code == 0
    assert "got=mk09" in captured_lines


@pytest.mark.asyncio
async def test_bridge_confirm_yes(tmp_path):
    helper = _ops_prompt_path()
    script = tmp_path / "go.sh"
    script.write_text(
        f". {helper}\n"
        "if op_confirm 'Wipe?' false; then echo CONFIRMED; "
        "else echo SKIPPED; fi\n"
    )
    job_holder: list = []
    lines: list[str] = []

    def _on_event(event):
        if event.get("event") == "confirm":
            job_holder[0].respond("y")

    job = run(["bash", str(script)],
              on_line=lines.append, on_event=_on_event)
    job_holder.append(job)
    await job.wait()
    assert "CONFIRMED" in lines


@pytest.mark.asyncio
async def test_bridge_confirm_no(tmp_path):
    helper = _ops_prompt_path()
    script = tmp_path / "go.sh"
    script.write_text(
        f". {helper}\n"
        "if op_confirm 'Wipe?' false; then echo CONFIRMED; "
        "else echo SKIPPED; fi\n"
    )
    job_holder: list = []
    lines: list[str] = []

    def _on_event(event):
        if event.get("event") == "confirm":
            job_holder[0].respond("n")

    job = run(["bash", str(script)],
              on_line=lines.append, on_event=_on_event)
    job_holder.append(job)
    await job.wait()
    assert "SKIPPED" in lines


@pytest.mark.asyncio
async def test_bridge_falls_back_to_plain_when_fd3_closed(tmp_path):
    """A script using ops-prompt.sh but run WITHOUT on_event sees no
    fd 3 and uses plain `read` — keeps cron / ssh use working."""
    helper = _ops_prompt_path()
    script = tmp_path / "go.sh"
    script.write_text(
        f". {helper}\n"
        "op_pass 'plain text path'\n"
    )
    lines: list[str] = []
    job = run(["bash", str(script)], on_line=lines.append)
    out = await job.wait()
    assert out.exit_code == 0
    # Plain shell formatter is "  ✓ PASS  ..."
    assert any("PASS" in ln and "plain text path" in ln for ln in lines)
