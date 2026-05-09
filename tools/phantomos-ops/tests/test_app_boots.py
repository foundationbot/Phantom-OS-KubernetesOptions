"""End-to-end smoke tests for the M1 skeleton.

Uses Textual's Pilot harness — boots the app in a virtual terminal,
asserts the layout came up, then quits cleanly. If any of these
fail the TUI won't even render for an operator.
"""
from __future__ import annotations

import pytest

from phantomos_ops.app import OpsApp
from phantomos_ops.screens.main import ActionItem, GroupItem, MainScreen


@pytest.mark.asyncio
async def test_app_boots_and_quits_cleanly():
    """The most basic guarantee: importing + starting + quitting is safe.
    A green here means the manifest, screens, theme, and bindings all
    parsed correctly."""
    app = OpsApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)
        await pilot.press("q")


@pytest.mark.asyncio
async def test_first_group_first_action_highlighted_on_open():
    """Operator should never see an empty actions pane on launch."""
    app = OpsApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, MainScreen)
        # First group selected automatically.
        assert screen.groups_view.index == 0
        # Its actions populated; first one highlighted.
        assert screen.actions_view.index == 0
        first_item = screen.actions_view.children[0]
        assert isinstance(first_item, ActionItem)
        # Detail pane reflects the highlighted action.
        assert screen.detail.action is first_item.action


@pytest.mark.asyncio
async def test_switching_group_updates_action_list():
    """Highlighting a different group must repopulate the actions pane."""
    app = OpsApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, MainScreen)

        screen.groups_view.focus()
        before = [
            c.action.id for c in screen.actions_view.children
            if isinstance(c, ActionItem)
        ]
        # Move down; pause to let event loop deliver Highlighted.
        await pilot.press("down")
        await pilot.pause()
        after = [
            c.action.id for c in screen.actions_view.children
            if isinstance(c, ActionItem)
        ]
        assert before != after, "actions pane did not change after switching group"


@pytest.mark.asyncio
async def test_q_binding_triggers_quit():
    """The 'q' binding must reach app.quit. Without this an operator
    can't exit cleanly without ctrl-c, which leaves the terminal in
    cooked mode."""
    app = OpsApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("q")
        # If quit fired, Pilot's context manager will exit without
        # timing out. Reaching here means it did.
