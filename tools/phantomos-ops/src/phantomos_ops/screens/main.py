"""Main screen — three-pane menu (groups · actions · detail).

M1 reads the in-code SAMPLE_MANIFEST so the layout is verifiable
end-to-end. M2 swaps in the YAML loader without touching this file.
"""
from __future__ import annotations

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.screen import Screen
from textual.widgets import Footer, ListItem, ListView, Static

from .. import env, safety
from ..manifest import Action, Group, Manifest


# ---------------------------------------------------------------------
# env header

class EnvBar(Static):
    """One-line status of host / robot / kubectl / online."""

    fingerprint: reactive[env.Fingerprint | None] = reactive(None, recompose=True)

    def on_mount(self) -> None:
        self.fingerprint = env.fingerprint()
        self.set_interval(5.0, self._refresh)

    def _refresh(self) -> None:
        self.fingerprint = env.fingerprint(refresh=True)

    def render(self) -> str:
        fp = self.fingerprint
        if fp is None:
            return ""
        host_part   = f"host {fp.host}"
        robot_part  = f"robot {fp.robot_id or '—'}"
        kc_glyph    = "✓" if fp.kubectl.available else "✗"
        kc_part     = f"kubectl {kc_glyph}"
        # M2 will add argocd / online state here. Keep the layout
        # stable so the bar doesn't reflow when we add to it.
        return f"  {host_part}   {robot_part}   {kc_part}"


# ---------------------------------------------------------------------
# group + action list rows

class GroupItem(ListItem):
    def __init__(self, group: Group):
        super().__init__(Static(group.title))
        self.group = group


class ActionItem(ListItem):
    def __init__(self, action: Action, gated_reason: str | None,
                 favorited: bool = False):
        style = safety.style(action.safety)
        prefix = f"[{style.css_class}]{style.glyph}[/{style.css_class}]"
        star = " ★" if favorited else ""
        text = f"{prefix}  {action.title}{star}"
        if gated_reason:
            text += f"   [dim](disabled: {gated_reason})[/dim]"
        super().__init__(Static(text, markup=True))
        self.action = action
        self.gated = gated_reason is not None
        self.favorited = favorited


# ---------------------------------------------------------------------
# detail pane

class DetailPane(Vertical):
    """Right-hand pane — full description of the highlighted action."""

    action: reactive[Action | None] = reactive(None, recompose=True)

    def compose(self) -> ComposeResult:
        a = self.action
        if a is None:
            yield Static("[dim]Pick an action to see details.[/dim]", markup=True)
            return

        sty = safety.style(a.safety)
        yield Static(a.title, classes="title")
        yield Static("─" * 40, classes="dim")
        yield Static(a.blurb, classes="blurb")
        meta_lines = [sty.word]
        if a.duration:
            meta_lines.append(a.duration)
        if a.requires:
            meta_lines.append("needs " + ", ".join(a.requires))
        if a.runs_on and set(a.runs_on) != {"robot", "dev"}:
            meta_lines.append("runs on " + ", ".join(a.runs_on))
        for line in meta_lines:
            yield Static(line, classes="meta")
        yield Static("", classes="meta")
        yield Static(
            f"[dim]▸ Show command (c)[/dim]",
            markup=True,
            classes="meta",
        )


# ---------------------------------------------------------------------
# screen

class MainScreen(Screen):
    """Three-pane menu. Default screen at app boot."""

    BINDINGS = [
        ("q", "app.quit", "Quit"),
        ("?", "help", "Help"),
        ("e", "edit_args", "Edit args"),
        ("f", "toggle_favorite", "Favorite"),
        ("slash", "search", "Search"),
    ]

    def __init__(self, manifest: Manifest):
        super().__init__()
        self.manifest = manifest

    def compose(self) -> ComposeResult:
        self.env_bar = EnvBar(id="env-bar")
        yield self.env_bar

        with Horizontal(id="main-grid"):
            self.groups_view = ListView(
                *(GroupItem(g) for g in sorted(self.manifest.groups, key=lambda x: x.order)),
                id="groups-pane",
            )
            yield self.groups_view

            self.actions_view = ListView(id="actions-pane")
            yield self.actions_view

            self.detail = DetailPane(id="detail-pane")
            yield self.detail

        yield Footer()

    async def on_mount(self) -> None:
        # Highlight first non-empty group → first action so the screen
        # never opens empty. If every group is empty (manifest only has
        # `groups:` and no `actions:`) we still mount cleanly with an
        # empty actions pane.
        ordered = sorted(self.manifest.groups, key=lambda x: x.order)
        for idx, group in enumerate(ordered):
            if self.manifest.actions_in(group.id):
                self.groups_view.index = idx
                await self._populate_actions(group)
                break
        # Focus the actions pane so Up/Down/Enter operate on actions
        # by default — that's the most common keyboard flow. To
        # switch groups, the operator clicks a group or uses Tab.
        if self.actions_view.children:
            self.actions_view.focus()

    async def _populate_actions(self, group: Group) -> None:
        # ListView.clear / append are async — await them so the
        # subsequent index assignment lands on a populated view.
        await self.actions_view.clear()
        fp = env.fingerprint()
        favorites: set[str] = self.app.state.favorites
        # Favorited actions sort to the top of the group; within each
        # bucket (favorited / not), preserve manifest order so
        # operators can still find things by mental position.
        actions = self.manifest.actions_in(group.id)
        favs = [a for a in actions if a.id in favorites]
        rest = [a for a in actions if a.id not in favorites]
        ordered = (*favs, *rest)
        items = [
            ActionItem(a, self._gate_reason(a, fp),
                       favorited=(a.id in favorites))
            for a in ordered
        ]
        if items:
            await self.actions_view.extend(items)
            self.actions_view.index = 0
            self._update_detail()
        else:
            self.detail.action = None

    def _gate_reason(self, action: Action, fp: env.Fingerprint) -> str | None:
        for cap in action.requires:
            if not fp.has_capability(cap):
                return f"needs {cap}"
        return None

    def _update_detail(self) -> None:
        idx = self.actions_view.index
        if idx is None:
            self.detail.action = None
            return
        item = self.actions_view.children[idx]
        if isinstance(item, ActionItem):
            self.detail.action = item.action

    # ----- event handlers --------------------------------------------

    async def on_list_view_highlighted(self, event: ListView.Highlighted) -> None:
        if event.list_view is self.groups_view:
            item = event.item
            if isinstance(item, GroupItem):
                await self._populate_actions(item.group)
        elif event.list_view is self.actions_view:
            self._update_detail()

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        """Enter on the actions pane fires the highlighted action.

        ListView consumes the 'enter' key before screen-level bindings
        see it, so we listen for the resulting Selected event.
        """
        if event.list_view is self.actions_view:
            self.action_run_selected()

    def action_help(self) -> None:
        from .help import HelpScreen
        self.app.push_screen(HelpScreen())

    def action_search(self) -> None:
        """Open the fuzzy-search modal. Picking a result navigates the
        menu to that action; pressing esc returns silently."""
        from .search import SearchScreen
        self.app.push_screen(
            SearchScreen(self.manifest),
            callback=self._on_search_dismissed,
        )

    def _on_search_dismissed(self, action_id: str | None) -> None:
        if not action_id:
            return
        action = self.manifest.by_id(action_id)
        if action is None:
            return
        # Find which group the action lives in and switch to it, then
        # highlight the action in the actions pane.
        ordered = sorted(self.manifest.groups, key=lambda x: x.order)
        for idx, g in enumerate(ordered):
            if g.id == action.group:
                self.groups_view.index = idx
                # Schedule the action highlight for after the
                # repopulate driven by the Highlighted handler.
                self.call_after_refresh(self._focus_action_id, action.id)
                break

    def _focus_action_id(self, action_id: str) -> None:
        for i, child in enumerate(self.actions_view.children):
            if isinstance(child, ActionItem) and child.action.id == action_id:
                self.actions_view.index = i
                self.actions_view.focus()
                return

    async def action_toggle_favorite(self) -> None:
        """Pin/unpin the highlighted action. Persists to state.json."""
        action = self._selected_action()
        if action is None:
            return
        favorites = self.app.state.favorites
        if action.id in favorites:
            favorites.discard(action.id)
        else:
            favorites.add(action.id)
        try:
            self.app.state.save()
        except Exception:  # pragma: no cover
            pass
        # Repopulate the current group so the favorited entry jumps
        # to the top (or unpinned drops back into manifest order).
        idx = self.groups_view.index
        if idx is not None:
            ordered = sorted(self.manifest.groups, key=lambda x: x.order)
            await self._populate_actions(ordered[idx])
            # Re-focus the same action so the operator's cursor doesn't
            # jump unexpectedly.
            self._focus_action_id(action.id)

    def action_run_selected(self) -> None:
        """Run the highlighted action with its default args.

        Form-aware actions skip the form on plain Enter — this is the
        "fast path" for operators who want defaults. Pressing 'e'
        opens the form for parameter tweaks.
        """
        action = self._selected_action()
        if action is None:
            return
        self._dispatch(action, command_override=None)

    def action_edit_args(self) -> None:
        """Open the parameter form for the highlighted action.

        Falls back to plain run if the action has no form."""
        action = self._selected_action()
        if action is None:
            return
        if action.form is None:
            self._dispatch(action, command_override=None)
            return
        from ..forms import get_form_class
        form_cls = get_form_class(action.form)
        if form_cls is None:
            # Manifest references an unknown form module — log into
            # manifest_errors-equivalent and fall back to plain run.
            self.app.bell()
            self._dispatch(action, command_override=None)
            return
        recalled = self.app.state.recall_form(action.id)
        self.app.push_screen(
            form_cls(action, recalled=recalled),
            callback=lambda cmd, a=action: self._on_form_dismissed(a, cmd),
        )

    def _selected_action(self):
        """Resolve the currently highlighted ActionItem, or None.

        Bells + returns None when nothing is selected or the entry
        is gated (requires not met)."""
        idx = self.actions_view.index
        if idx is None:
            self.app.bell()
            return None
        item = self.actions_view.children[idx]
        if not isinstance(item, ActionItem) or item.gated:
            self.app.bell()
            return None
        return item.action

    def _dispatch(self, action, command_override: tuple[str, ...] | None) -> None:
        """Final stage: confirm if needed, then push RunScreen."""
        if safety.needs_confirm(action.safety) \
                and action.id not in self.app.confirmed_this_session:
            from .confirm import ConfirmScreen
            self.app.push_screen(
                ConfirmScreen(action),
                callback=lambda confirmed, a=action, c=command_override:
                    self._on_confirmed(a, confirmed, c),
            )
            return
        self._launch(action, command_override)

    def _launch(self, action, command_override) -> None:
        from .run import RunScreen
        self.app.push_screen(RunScreen(action, command=command_override))

    def _on_confirmed(self, action, confirmed: bool | None,
                      command_override) -> None:
        if not confirmed:
            return
        self.app.confirmed_this_session.add(action.id)
        self._launch(action, command_override)

    def _on_form_dismissed(self, action,
                           cmd: tuple[str, ...] | None) -> None:
        if cmd is None:
            return  # Cancel / esc
        # Persist the operator's choices for next time. The form
        # screen exposed current_values via its instance — we read
        # from state via the screen still on the stack? No — once
        # dismissed it's gone. We persist via the form before
        # dismiss; here we just dispatch to the runner.
        self._dispatch(action, command_override=cmd)
