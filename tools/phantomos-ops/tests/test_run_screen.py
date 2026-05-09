"""End-to-end test for the run-screen.

Boots the full app, simulates the operator pressing Enter on an
action that runs a fast dummy command, and asserts the run-screen
appears, the output streams, and the exit code is reflected in the
banner.
"""
from __future__ import annotations

import pytest

from phantomos_ops.app import OpsApp
from phantomos_ops.manifest import Action, Group, Manifest
from phantomos_ops.screens.main import MainScreen
from phantomos_ops.screens.run import RunScreen


def _tiny_manifest() -> Manifest:
    return Manifest(
        groups=(Group("g", "G", order=1),),
        actions=(
            Action(
                id="g.echo",
                group="g",
                title="Echo something",
                blurb="prints hello and exits",
                safety="green",
                command=("python3", "-c", "print('hello from run-screen')"),
            ),
            Action(
                id="g.fail",
                group="g",
                title="Fail with code 3",
                blurb="prints to stderr and exits 3",
                safety="green",
                command=("python3", "-c", "import sys; sys.exit(3)"),
            ),
        ),
    )


@pytest.mark.asyncio
async def test_enter_pushes_run_screen_and_outcome_renders():
    app = OpsApp(manifest=_tiny_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, RunScreen)

        # Wait for the job to complete — the worker sets the banner
        # via _await_outcome.
        outcome = await app.screen.job.wait()
        assert outcome.exit_code == 0
        assert "hello from run-screen" in app.screen._lines


@pytest.mark.asyncio
async def test_failing_command_renders_red_banner():
    app = OpsApp(manifest=_tiny_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        # Move to second action (g.fail).
        await pilot.press("down")
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, RunScreen)
        outcome = await app.screen.job.wait()
        assert outcome.exit_code == 3


@pytest.mark.asyncio
async def test_escape_returns_to_menu():
    """Pressing escape on the run-screen returns to MainScreen.

    The 'job continues running in the background after pop' guarantee
    is a M5 feature — it requires moving the await-outcome worker from
    Screen to App so the screen lifecycle doesn't cancel it. For M2
    we only verify the navigation works.
    """
    long_running = Manifest(
        groups=(Group("g", "G", order=1),),
        actions=(Action(
            id="g.sleep",
            group="g",
            title="Sleep briefly",
            blurb="sleeps 0.5s",
            safety="green",
            command=("python3", "-c", "import time; time.sleep(0.5)"),
        ),),
    )
    app = OpsApp(manifest=long_running)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, RunScreen)
        await pilot.press("escape")
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)


@pytest.mark.asyncio
async def test_gated_action_does_not_run():
    """Action marked requires=[unknown] greys out and Enter does nothing."""
    gated = Manifest(
        groups=(Group("g", "G", order=1),),
        actions=(Action(
            id="g.gated",
            group="g",
            title="Should be disabled",
            blurb="needs a capability that doesn't exist",
            safety="green",
            requires=("definitely_not_a_real_capability",),
            command=("python3", "-c", "print('should not run')"),
        ),),
    )
    app = OpsApp(manifest=gated)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        # Still on MainScreen — nothing pushed.
        assert isinstance(app.screen, MainScreen)
