"""Recovery screen.

Pushed by the app's exception boundary when a widget error escapes a
screen handler. Replaces the broken screen with a calm, branded
recovery prompt instead of dropping the operator into a Python
traceback in their terminal.

The full traceback is written to
~/.local/state/phantomos-ops/crash.log for forensics; the operator
sees a one-line summary plus three options: R reload, Q quit, L log
path. We deliberately don't show the traceback inline — operators
running over SSH on Jetsons don't need a wall of Python in their
terminal, and the log file is one shell command away.
"""
from __future__ import annotations

from pathlib import Path

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Static


CRASH_LOG_PATH = Path.home() / ".local" / "state" / "phantomos-ops" / "crash.log"


class RecoveryScreen(ModalScreen[str]):
    """Resolves to "reload" or "quit"."""

    BINDINGS = [
        Binding("r", "reload", "Reload"),
        Binding("q", "quit", "Quit"),
        Binding("l", "show_log_path", "Log"),
    ]

    def __init__(self, summary: str, log_path: Path = CRASH_LOG_PATH):
        super().__init__()
        self.summary = summary
        self.log_path = log_path

    def compose(self) -> ComposeResult:
        with Vertical(id="recovery-pane"):
            yield Static("⚠  Something unexpected happened",
                         id="recovery-title")
            yield Static("─" * 60, classes="dim")
            yield Static(self.summary, id="recovery-summary")
            yield Static(
                f"\n[dim]Traceback saved to:[/dim]\n  {self.log_path}",
                id="recovery-log-path",
                markup=True,
            )
            with Horizontal(id="recovery-buttons"):
                yield Button("Reload  (R)", id="reload-btn", variant="primary")
                yield Button("Quit  (Q)",   id="quit-btn",   variant="default")

    @on(Button.Pressed, "#reload-btn")
    def _on_reload_btn(self, _event: Button.Pressed) -> None:
        self.dismiss("reload")

    @on(Button.Pressed, "#quit-btn")
    def _on_quit_btn(self, _event: Button.Pressed) -> None:
        self.dismiss("quit")

    def action_reload(self) -> None:
        self.dismiss("reload")

    def action_quit(self) -> None:
        self.dismiss("quit")

    def action_show_log_path(self) -> None:
        # Already shown in the body — the binding lets the operator
        # focus the log line for screen-reader / copy-paste flows
        # without us re-rendering anything.
        self.app.bell()


def write_crash_log(traceback_text: str,
                    path: Path = CRASH_LOG_PATH) -> Path:
    """Append the traceback to the crash log, rotating once at 1 MB.

    Returns the path written for callers that want to surface it.
    Failure to write is silent — the caller is already handling
    *another* failure and shouldn't crash on the recovery path.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > 1_000_000:
            backup = path.with_suffix(".log.1")
            try:
                path.replace(backup)
            except OSError:
                pass
        from datetime import datetime
        with path.open("a") as f:
            f.write(f"\n=== {datetime.now().isoformat()} ===\n")
            f.write(traceback_text)
            f.write("\n")
    except OSError:
        pass
    return path
