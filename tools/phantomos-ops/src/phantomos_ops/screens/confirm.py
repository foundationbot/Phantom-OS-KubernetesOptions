"""Confirmation modal for red (destructive) actions.

Per docs/ops-tui-user-guide.md: red actions must be gated by a
typed magic word so muscle memory cannot fire them. The word is
action-specific (`reset`, `wipe`, `prune`, `bootstrap`, `proceed`)
to make accidental triggering across modals impossible.

Design notes:
- Live as you type: the Proceed button enables only when the input
  exactly matches the action's confirm_word. No partial matching,
  no whitespace tolerance — the operator is committing to a
  destructive operation, exact precision is the point.
- esc cancels back to MainScreen, no side effects.
- Confirmation memory is a per-session set on the app; once
  confirmed, the modal is skipped for the same action id until quit.
"""
from __future__ import annotations

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Static

from ..manifest import Action


class ConfirmScreen(ModalScreen[bool]):
    """Modal that resolves to True (proceed) or False (cancel)."""

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
    ]

    can_proceed: reactive[bool] = reactive(False)

    def __init__(self, action: Action):
        super().__init__()
        self.action = action

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-pane", classes="confirm-pane"):
            yield Static(f"⚠  {self.action.title}", id="confirm-title")
            yield Static("─" * 60, classes="dim")
            yield Static(self.action.blurb, id="confirm-blurb")
            yield Static(
                f"Type [b]{self.action.confirm_word!r}[/b] to proceed:",
                id="confirm-prompt",
                markup=True,
            )
            self.input = Input(placeholder=self.action.confirm_word,
                               id="confirm-input")
            yield self.input
            with Horizontal(id="confirm-buttons"):
                yield Button("Cancel", id="cancel-btn", variant="default")
                self.proceed_btn = Button("Proceed", id="proceed-btn",
                                          variant="error", disabled=True)
                yield self.proceed_btn

    def on_mount(self) -> None:
        self.input.focus()

    @on(Input.Changed)
    def _on_input_changed(self, event: Input.Changed) -> None:
        # Exact match — no strip, no case-fold. Belt-and-braces against
        # accidental confirms.
        self.can_proceed = event.value == self.action.confirm_word
        self.proceed_btn.disabled = not self.can_proceed

    @on(Input.Submitted)
    def _on_input_submitted(self, event: Input.Submitted) -> None:
        # Pressing Enter inside the input — same as clicking Proceed,
        # but only when the word matches.
        if self.can_proceed:
            self.dismiss(True)

    @on(Button.Pressed, "#cancel-btn")
    def _on_cancel(self, event: Button.Pressed) -> None:
        self.dismiss(False)

    @on(Button.Pressed, "#proceed-btn")
    def _on_proceed(self, event: Button.Pressed) -> None:
        if self.can_proceed:
            self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)
