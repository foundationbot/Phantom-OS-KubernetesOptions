"""Tests for the destructive-action confirmation modal."""
from __future__ import annotations

import pytest

from phantomos_ops.app import OpsApp
from phantomos_ops.manifest import Action, Group, Manifest
from phantomos_ops.screens.confirm import ConfirmScreen
from phantomos_ops.screens.main import MainScreen
from phantomos_ops.screens.run import RunScreen


def _red_manifest() -> Manifest:
    return Manifest(
        groups=(Group("g", "G", order=1),),
        actions=(Action(
            id="g.boom",
            group="g",
            title="Detonate the test bench",
            blurb="this would do something destructive",
            safety="red",
            confirm_word="boom",
            command=("python3", "-c", "print('boom')"),
        ),),
    )


@pytest.mark.asyncio
async def test_red_action_pushes_confirm_modal_not_run_screen():
    """Enter on a red action must NOT immediately spawn the script."""
    app = OpsApp(manifest=_red_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        # Confirm modal up, run-screen NOT up.
        assert isinstance(app.screen, ConfirmScreen)


@pytest.mark.asyncio
async def test_wrong_word_does_not_proceed():
    """The Proceed button stays disabled until the magic word matches."""
    app = OpsApp(manifest=_red_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        confirm = app.screen
        assert isinstance(confirm, ConfirmScreen)
        # Wrong word.
        for ch in "wrong":
            await pilot.press(ch)
        await pilot.pause()
        assert not confirm.can_proceed
        # Pressing enter must not fire the action — modal stays.
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)


@pytest.mark.asyncio
async def test_correct_word_unlocks_proceed_and_runs():
    app = OpsApp(manifest=_red_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        confirm = app.screen
        assert isinstance(confirm, ConfirmScreen)
        for ch in "boom":
            await pilot.press(ch)
        await pilot.pause()
        assert confirm.can_proceed
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, RunScreen)


@pytest.mark.asyncio
async def test_escape_cancels_modal():
    app = OpsApp(manifest=_red_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.press("escape")
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)


@pytest.mark.asyncio
async def test_confirmation_memory_skips_modal_on_repeat():
    """After confirming once in this session, a re-run of the same
    red action must skip the modal — operator just retried."""
    app = OpsApp(manifest=_red_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        # First run: confirm.
        await pilot.press("enter")
        await pilot.pause()
        for ch in "boom":
            await pilot.press(ch)
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, RunScreen)
        # Wait for it to finish, then back to menu.
        await app.screen.job.wait()
        await pilot.press("escape")
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)
        # Second run: should go straight to RunScreen.
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, RunScreen)
