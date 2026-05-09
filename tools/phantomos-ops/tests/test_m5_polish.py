"""M5 polish: help overlay, fuzzy search, favorites."""
from __future__ import annotations

import pytest

from phantomos_ops.app import OpsApp
from phantomos_ops.manifest import Action, Group, Manifest
from phantomos_ops.screens.help import HelpScreen
from phantomos_ops.screens.main import ActionItem, MainScreen
from phantomos_ops.screens.search import SearchScreen, _score
from phantomos_ops.state import State


def _three_actions_manifest() -> Manifest:
    return Manifest(
        groups=(
            Group("a", "A group", order=1),
            Group("b", "B group", order=2),
        ),
        actions=(
            Action(id="a.first",  group="a", title="First action",
                   blurb="x", safety="green", command=("true",)),
            Action(id="a.second", group="a", title="Second action",
                   blurb="x", safety="green", command=("true",)),
            Action(id="b.third",  group="b", title="Tail logs of pod",
                   blurb="x", safety="green", command=("true",)),
        ),
    )


# ---------- help overlay ----------

@pytest.mark.asyncio
async def test_question_mark_opens_help():
    app = OpsApp(manifest=_three_actions_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("question_mark")
        await pilot.pause()
        assert isinstance(app.screen, HelpScreen)


@pytest.mark.asyncio
async def test_help_escape_closes():
    app = OpsApp(manifest=_three_actions_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("question_mark")
        await pilot.pause()
        assert isinstance(app.screen, HelpScreen)
        await pilot.press("escape")
        await pilot.pause()
        assert isinstance(app.screen, MainScreen)


# ---------- fuzzy search ----------

def test_score_exact_substring_beats_subsequence():
    assert _score("logs", "Tail positronic-control logs") > \
        _score("logs", "Diagnose unhealthy pod")


def test_score_returns_zero_on_no_match():
    assert _score("xyzzy", "Tail positronic-control logs") == 0


def test_score_empty_query_returns_zero():
    assert _score("", "anything") == 0


@pytest.mark.asyncio
async def test_slash_opens_search_modal():
    app = OpsApp(manifest=_three_actions_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("slash")
        await pilot.pause()
        assert isinstance(app.screen, SearchScreen)


@pytest.mark.asyncio
async def test_search_picks_action_and_returns_to_menu():
    app = OpsApp(manifest=_three_actions_manifest())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("slash")
        await pilot.pause()
        # Type a query that matches only the third action.
        for ch in "tail":
            await pilot.press(ch)
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        # Back on main; cursor should be on the matched action.
        assert isinstance(app.screen, MainScreen)


# ---------- favorites ----------

@pytest.mark.asyncio
async def test_favorite_persists_and_floats_action_to_top(tmp_path):
    """Pressing 'f' on the second action favorites it; on next
    populate, that action sits at index 0."""
    state = State()
    app = OpsApp(manifest=_three_actions_manifest(), state=state)
    async with app.run_test() as pilot:
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, MainScreen)
        # Move down to the second action.
        await pilot.press("down")
        await pilot.pause()
        item = screen.actions_view.children[screen.actions_view.index]
        target_id = item.action.id
        # Favorite it.
        await pilot.press("f")
        await pilot.pause()
        # Still on the same action (cursor preserved).
        new_item = screen.actions_view.children[screen.actions_view.index]
        assert new_item.action.id == target_id
        # And the favorited item is now at index 0 of its group.
        first_item = screen.actions_view.children[0]
        assert isinstance(first_item, ActionItem)
        assert first_item.action.id == target_id
        assert first_item.favorited is True
        # And the state reflects it.
        assert target_id in state.favorites


@pytest.mark.asyncio
async def test_favorite_toggles_off():
    state = State()
    app = OpsApp(manifest=_three_actions_manifest(), state=state)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("f")
        await pilot.pause()
        assert len(state.favorites) == 1
        await pilot.press("f")
        await pilot.pause()
        assert len(state.favorites) == 0
