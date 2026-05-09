"""Modal screens used by the bridge to ask the operator for input.

Pushed by RunScreen when a bridge `ask` or `confirm` event arrives;
the modal resolves to the operator's answer (or a default on
cancel) and the runner's respond() feeds it back to the script's
stdin.
"""
from __future__ import annotations

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Static


class AskModal(ModalScreen[str]):
    """String input modal — resolves to the typed value (or default
    on esc). When ``kind="password"``, the Input renders masked.
    """

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, label: str, default: str = "", kind: str = "string"):
        super().__init__()
        self.label = label
        self.default = default
        self.kind = kind

    def compose(self) -> ComposeResult:
        with Vertical(id="ask-pane", classes="ask-pane"):
            yield Static(self.label, id="ask-label")
            # password: never pre-fill the input — that would defeat
            # the masking. Show only a placeholder hinting "default
            # will be used on empty submit". Visible string fields
            # pre-fill with the default so the operator can edit.
            is_password = (self.kind == "password")
            self.input = Input(
                value="" if is_password else self.default,
                placeholder=("password" if is_password
                             else (self.default or "answer")),
                password=is_password,
                id="ask-input",
            )
            yield self.input
            with Horizontal(id="ask-buttons"):
                yield Button("Cancel", id="cancel-btn", variant="default")
                yield Button("OK", id="ok-btn", variant="primary")

    def on_mount(self) -> None:
        self.input.focus()

    @on(Input.Submitted)
    def _on_submit(self, _event: Input.Submitted) -> None:
        self.dismiss(self.input.value or self.default)

    @on(Button.Pressed, "#ok-btn")
    def _on_ok(self, _event: Button.Pressed) -> None:
        self.dismiss(self.input.value or self.default)

    @on(Button.Pressed, "#cancel-btn")
    def _on_cancel(self, _event: Button.Pressed) -> None:
        self.dismiss(self.default)

    def action_cancel(self) -> None:
        self.dismiss(self.default)


class ConfirmYesNoModal(ModalScreen[bool]):
    """Yes/No modal for op_confirm. Resolves to True (yes) or False
    (no/cancel/esc).
    """

    BINDINGS = [
        Binding("escape", "no", "No"),
        Binding("y", "yes", "Yes"),
        Binding("n", "no", "No"),
    ]

    def __init__(self, label: str, default: bool = False):
        super().__init__()
        self.label = label
        self.default = default

    def compose(self) -> ComposeResult:
        with Vertical(id="ynconfirm-pane", classes="ynconfirm-pane"):
            yield Static(self.label, id="ynconfirm-label")
            with Horizontal(id="ynconfirm-buttons"):
                yield Button("No  (n)",  id="no-btn",  variant="default")
                yield Button("Yes (y)", id="yes-btn", variant="primary")

    def action_yes(self) -> None:
        self.dismiss(True)

    def action_no(self) -> None:
        self.dismiss(False)

    @on(Button.Pressed, "#yes-btn")
    def _on_yes(self, _event: Button.Pressed) -> None:
        self.dismiss(True)

    @on(Button.Pressed, "#no-btn")
    def _on_no(self, _event: Button.Pressed) -> None:
        self.dismiss(False)
