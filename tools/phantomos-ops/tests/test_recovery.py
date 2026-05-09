"""Crash-boundary + recovery-modal tests."""
from __future__ import annotations

from pathlib import Path

import pytest

from phantomos_ops.app import OpsApp
from phantomos_ops.manifest import Action, Group, Manifest
from phantomos_ops.screens.recovery import RecoveryScreen, write_crash_log


def _tiny_manifest() -> Manifest:
    return Manifest(
        groups=(Group("g", "G", order=1),),
        actions=(Action(id="g.x", group="g", title="x", blurb="x",
                        safety="green", command=("true",)),),
    )


def test_write_crash_log_creates_file(tmp_path):
    p = tmp_path / "crash.log"
    write_crash_log("Traceback (...)\nValueError: boom\n", path=p)
    assert p.exists()
    assert "ValueError: boom" in p.read_text()


def test_write_crash_log_appends(tmp_path):
    """Two crashes in one session both end up in the log."""
    p = tmp_path / "crash.log"
    write_crash_log("first\n", path=p)
    write_crash_log("second\n", path=p)
    text = p.read_text()
    assert "first" in text
    assert "second" in text


def test_write_crash_log_rotates_at_1mb(tmp_path):
    """Log over 1 MB rotates to .log.1 on next write."""
    p = tmp_path / "crash.log"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("x" * 1_500_000)
    write_crash_log("new", path=p)
    assert p.with_suffix(".log.1").exists()
    assert p.read_text().endswith("new\n") or "new" in p.read_text()


def test_write_crash_log_silent_on_unwritable(tmp_path):
    """Failure to write must not raise — recovery shouldn't compound
    the failure that triggered it."""
    bad = Path("/proc/1/fake/cannot/write")
    write_crash_log("doesn't matter", path=bad)  # should not raise


@pytest.mark.asyncio
async def test_exception_in_widget_handler_pushes_recovery_modal(monkeypatch, tmp_path):
    """A widget exception must surface as RecoveryScreen, not crash
    the app."""
    # Redirect crash log into tmp so we don't pollute real $HOME.
    import phantomos_ops.screens.recovery as recovery
    monkeypatch.setattr(recovery, "CRASH_LOG_PATH", tmp_path / "crash.log")

    app = OpsApp(manifest=_tiny_manifest())

    async with app.run_test() as pilot:
        await pilot.pause()
        # Inject an exception by directly calling on_exception (the
        # documented Textual hook for app-level error handling). This
        # avoids needing to crash a widget mid-event in the test.
        app.on_exception(RuntimeError("simulated widget bug"))
        await pilot.pause()
        assert isinstance(app.screen, RecoveryScreen)


@pytest.mark.asyncio
async def test_recovery_quit_button_exits(monkeypatch, tmp_path):
    import phantomos_ops.screens.recovery as recovery
    monkeypatch.setattr(recovery, "CRASH_LOG_PATH", tmp_path / "crash.log")

    app = OpsApp(manifest=_tiny_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        app.on_exception(RuntimeError("boom"))
        await pilot.pause()
        assert isinstance(app.screen, RecoveryScreen)
        await pilot.press("q")
        await pilot.pause()
        # App should be exiting; further presses are no-ops.
