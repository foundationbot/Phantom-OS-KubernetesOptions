"""Help overlay — keys, actions, about.

Pushed by the '?' binding on MainScreen. Three tabs let an operator
discover what to type without leaving the menu they're already in.
Closing returns to wherever they came from.
"""
from __future__ import annotations

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Static, TabbedContent, TabPane

from .. import __version__


_KEYS_TEXT = """\
[b]Navigation[/b]
  ↑ ↓        move within the list
  ← →        switch panes (groups → actions → detail)
  tab        next pane
  /          fuzzy search across all actions
  g 1..6     jump to group N

[b]Action[/b]
  ↵          run the selected action
  e          open the parameter form (form-aware actions)
  d          run with --dry-run if the script supports it
  c          toggle command preview in the detail pane
  f          favorite (pinned to top of the group)

[b]Job[/b]
  ctrl-c     cancel the running job
  p          pause autoscroll
  s          save the running output to a file
  esc        return to menu, keep job running

[b]Modals[/b]
  esc        cancel
  ↵          confirm / run when the input matches the magic word

[b]Global[/b]
  ?          this overlay
  q          quit
"""


_ACTIONS_BLURB = """\
The menu groups every operator-facing script in this repo by intent,
not by file name.

  Bootstrap & Host    First-time bringup, host config, real-time CPU
  Workloads           positronic-control + locomotion lifecycle
  Recording & Streams Recorder commands (start, stop, ping, raw)
  Registry            Prime, prune, validate, recover the local cache
  Builds              phantom-models / phantom-policies images
  Diagnostics         Perfmon, validate, diagnose

[b]Safety markers[/b]
  ●  green   read-only — fires immediately on Enter
  ●  yellow  changes state but reversible — fires on Enter
  ⚠  red     destructive — confirm modal with magic word

For the full list of actions and the YAML schema, see the
developer guide:  docs/ops-tui-dev-guide.md
"""


def _about_text() -> str:
    return (
        f"phantomos ops v{__version__}\n\n"
        "Textual TUI launcher for the Phantom-OS-KubernetesOptions\n"
        "fleet operator scripts.\n\n"
        "Operator guide:   docs/ops-tui-user-guide.md\n"
        "Developer guide:  docs/ops-tui-dev-guide.md\n"
        "Source:           tools/phantomos-ops/\n"
    )


class HelpScreen(ModalScreen[None]):
    """Three-tab help overlay."""

    BINDINGS = [
        Binding("escape", "close", "Close"),
        Binding("?", "close", "Close"),
        Binding("q", "close", "Close"),
    ]

    def compose(self) -> ComposeResult:
        with Vertical(id="help-pane"):
            with TabbedContent(initial="keys"):
                with TabPane("Keys", id="keys"):
                    yield Static(_KEYS_TEXT, markup=True, id="help-keys")
                with TabPane("Actions", id="actions"):
                    yield Static(_ACTIONS_BLURB, markup=True,
                                 id="help-actions")
                with TabPane("About", id="about"):
                    yield Static(_about_text(), id="help-about")
            yield Static("[dim]esc / ? / q to close[/dim]", markup=True,
                         id="help-footer")

    def action_close(self) -> None:
        self.dismiss(None)
