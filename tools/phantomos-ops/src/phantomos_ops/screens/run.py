"""Running-job screen — streams subprocess output via RichLog.

Pushed by MainScreen when an action fires. The screen runs to
completion and then shows a banner with the exit code; the operator
can press esc to return to the menu (job continues in background) or
ctrl-c to cancel.

Note: M2 keeps this single-job — pressing run again on the menu while
a job runs replaces the screen. M5 adds concurrent job support and
the header badge counter.
"""
from __future__ import annotations

import shlex
from pathlib import Path
from typing import Callable

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import Screen
from textual.widgets import RichLog, Static

from ..manifest import Action
from ..repo import find_repo_root_or_error
from ..runner import Job, Outcome, run


class RunScreen(Screen):
    """Streaming output for one running action."""

    BINDINGS = [
        Binding("escape", "back_to_menu", "Back to menu"),
        Binding("ctrl+c", "cancel", "Cancel"),
        Binding("p", "toggle_pause", "Pause scroll"),
        Binding("s", "save_log", "Save log"),
    ]

    def __init__(self, action: Action, command: tuple[str, ...] | None = None):
        super().__init__()
        self.action = action
        self.command = command if command is not None else action.command
        self.job: Job | None = None
        self._paused = False
        self._lines: list[str] = []   # buffer for save_log

    def compose(self) -> ComposeResult:
        with Vertical(id="run-pane"):
            yield Static(f"▶  {self.action.title}", classes="title")
            yield Static("─" * 60, classes="dim")
            yield Static(self._command_preview(), classes="cmd")
            self.log_view = RichLog(highlight=False, markup=False, wrap=False,
                                    auto_scroll=True, id="run-log")
            yield self.log_view
            self.banner = Static("", id="run-banner")
            yield self.banner

    def _command_preview(self) -> str:
        # quote-safe rendering for the operator's eyeball check
        return "$ " + " ".join(shlex.quote(s) for s in self.command)

    def on_mount(self) -> None:
        repo_root, err = find_repo_root_or_error()
        if repo_root is None:
            # Render the error in the banner instead of trying to run
            # the script — without a repo root, `bash scripts/foo.sh`
            # is guaranteed to fail with a misleading "No such file"
            # message that hides the real cause.
            self.banner.update(
                f"[red]✗ {err}[/red]"
            )
            for line in (err or "").splitlines():
                self.log_view.write(line)
            return
        self.job = run(
            list(self.command),
            on_line=self._on_line,
            cwd=str(repo_root),
        )
        # Watch the job to render the final banner. Worker keeps
        # running even if the operator presses esc back to the menu.
        self.run_worker(self._await_outcome(), exclusive=False)

    # ----- runner integration ----------------------------------------

    def _on_line(self, line: str) -> None:
        if self._paused:
            # Lines still arrive (we keep them so save_log captures
            # everything), but we stop pushing them into the log
            # widget. Resuming is M5's pause-scroll bookmark — for
            # M2 the simple toggle stops new appends.
            self._lines.append(line)
            return
        self._lines.append(line)
        self.log_view.write(line)

    async def _await_outcome(self) -> None:
        assert self.job is not None
        outcome = await self.job.wait()
        self._render_banner(outcome)

    def _render_banner(self, outcome: Outcome) -> None:
        if outcome.error:
            txt = f"[red]✗ failed to start: {outcome.error}[/red]"
        elif outcome.cancelled:
            txt = (f"[yellow]✗ cancelled (signal exit {outcome.exit_code}, "
                   f"{outcome.duration_s:.1f}s)[/yellow]")
        elif outcome.exit_code == 0:
            txt = (f"[green]✓ completed in {outcome.duration_s:.1f}s[/green]")
        else:
            txt = (f"[red]✗ exit {outcome.exit_code} after "
                   f"{outcome.duration_s:.1f}s[/red]")
        self.banner.update(txt)

    # ----- bindings --------------------------------------------------

    def action_back_to_menu(self) -> None:
        # Pop without cancelling — the worker awaiting the outcome
        # is still running on the App, so the job continues.
        self.app.pop_screen()

    def action_cancel(self) -> None:
        if self.job is not None:
            self.job.cancel()

    def action_toggle_pause(self) -> None:
        self._paused = not self._paused
        suffix = " [paused]" if self._paused else ""
        self.banner.update(f"[dim]autoscroll{suffix}[/dim]")

    def action_save_log(self) -> None:
        out = Path.home() / ".local" / "state" / "phantomos-ops" / "logs"
        out.mkdir(parents=True, exist_ok=True)
        from datetime import datetime
        stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
        path = out / f"{self.action.id}-{stamp}.log"
        path.write_text("\n".join(self._lines) + "\n")
        self.banner.update(f"[dim]saved → {path}[/dim]")
