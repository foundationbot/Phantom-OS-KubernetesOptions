"""ActionForm base — minimal extension surface for parameter forms.

A form module subclasses ActionForm and implements two methods:

    compose_fields()  yields rows of (label, widget) — the form
                      builds the layout, registers the widget by its
                      id, and persists its value across sessions.
    to_command()      returns the argv list to run, derived from the
                      current field values.

The base class handles: form rendering, live command preview, value
persistence per action id, Cancel / Run buttons, plumbing into the
runner. Form modules are kept small and focused on the per-action
shape; everything generic lives here.
"""
from __future__ import annotations

import shlex
from typing import Any, Iterable

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, Static, Switch

from ..manifest import Action


# A row is (label_text, widget). We don't constrain the widget type —
# anything that exposes a .value attribute and an Input.Changed-style
# event is acceptable. Most fields are Input or Switch.
FieldRow = tuple[str, Any]


class ActionForm(ModalScreen[tuple[str, ...] | None]):
    """Base class for parameter forms.

    Subclasses implement compose_fields() and to_command(). The screen
    resolves to either the argv to run (Run pressed) or None (Cancel /
    esc).
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
    ]

    # Subclasses populate this in compose_fields() via .field().
    # Public so to_command() can look up values via self.value(id).
    field_widgets: dict[str, Any]

    def __init__(self, action: Action, recalled: dict[str, Any] | None = None):
        super().__init__()
        self.action = action
        self.field_widgets = {}
        # Last-used values restored from state.json. Subclasses look
        # these up via self.recalled.get(field_id, default).
        self.recalled: dict[str, Any] = recalled or {}

    # ----- subclass extension surface --------------------------------

    def compose_fields(self) -> Iterable[FieldRow]:
        """Override in subclasses. Yield (label, widget) rows.

        Each widget MUST have an `id` set so the base class can look
        it up in to_command() via self.value(id). Use self.field()
        to register a widget AND get the labelled row in one go.
        """
        raise NotImplementedError

    def to_command(self) -> list[str]:
        """Override in subclasses. Return argv built from current
        field values. Called on every field change to refresh the
        live preview, and once on Run."""
        raise NotImplementedError

    # ----- helpers used by subclasses --------------------------------

    def field(self, label: str, widget: Any) -> FieldRow:
        """Register a widget by its id and return the row tuple.

        Use as: yield self.field("Label", Input(id="myfield"))
        Then in to_command(): self.value("myfield").
        """
        if not getattr(widget, "id", None):
            raise ValueError("ActionForm fields must have an explicit id")
        self.field_widgets[widget.id] = widget
        return (label, widget)

    def value(self, field_id: str) -> Any:
        w = self.field_widgets[field_id]
        return getattr(w, "value", None)

    # ----- screen plumbing -------------------------------------------

    def compose(self) -> ComposeResult:
        with Vertical(id="form-pane"):
            yield Static(self.action.title, classes="title")
            yield Static("─" * 60, classes="dim")
            with Vertical(id="form-fields"):
                for label, widget in self.compose_fields():
                    with Horizontal(classes="form-row"):
                        yield Label(label, classes="form-label")
                        yield widget
            yield Static("Command preview", classes="meta")
            self.preview = Static("", id="form-preview", markup=False)
            yield self.preview
            with Horizontal(id="form-buttons"):
                yield Button("Cancel", id="cancel-btn", variant="default")
                yield Button("Run", id="run-btn", variant="primary")

    def on_mount(self) -> None:
        self._refresh_preview()
        # Focus the first input so Tab moves through fields naturally.
        for widget in self.field_widgets.values():
            if hasattr(widget, "focus"):
                widget.focus()
                break

    @on(Input.Changed)
    def _on_input_changed(self, _event: Input.Changed) -> None:
        self._refresh_preview()

    @on(Switch.Changed)
    def _on_switch_changed(self, _event: Switch.Changed) -> None:
        self._refresh_preview()

    def _refresh_preview(self) -> None:
        try:
            cmd = self.to_command()
        except Exception as exc:  # pragma: no cover — subclass bug
            self.preview.update(f"[error: {exc}]")
            return
        self.preview.update("$ " + " ".join(shlex.quote(s) for s in cmd))

    # ----- buttons ---------------------------------------------------

    @on(Button.Pressed, "#cancel-btn")
    def _on_cancel_btn(self, event: Button.Pressed) -> None:
        self.dismiss(None)

    @on(Button.Pressed, "#run-btn")
    def _on_run_btn(self, event: Button.Pressed) -> None:
        self._persist_and_dismiss()

    @on(Input.Submitted)
    def _on_submitted(self, _event: Input.Submitted) -> None:
        # Enter inside any input — same as Run.
        self._persist_and_dismiss()

    def _persist_and_dismiss(self) -> None:
        cmd = tuple(self.to_command())
        # Save the operator's choices so the next open of this form
        # restores them. Failure to persist is non-fatal — the form
        # still resolves to the command, the operator just loses
        # remembered values for next time.
        try:
            self.app.state.remember_form(self.action.id,
                                         self.current_values())
            self.app.state.save()
        except Exception:  # pragma: no cover
            pass
        self.dismiss(cmd)

    def action_cancel(self) -> None:
        self.dismiss(None)

    def current_values(self) -> dict[str, Any]:
        """Return {field_id: current_value} for state persistence."""
        return {fid: self.value(fid) for fid in self.field_widgets}


# ---------------------------------------------------------------------
# Form registry.
#
# Manifest's `form: <name>` field references one of these. Adding a
# new form module = one line here + the module file under forms/.

def get_form_class(name: str):
    """Resolve a form name from manifest.yaml to its ActionForm class.

    Returns None if the name is unknown — caller falls back to the
    launcher path (no form, run command directly with defaults).
    """
    if name == "positronic_logs":
        from .positronic_logs import PositronicLogsForm
        return PositronicLogsForm
    if name == "positronic_exec":
        from .positronic_exec import PositronicExecForm
        return PositronicExecForm
    if name == "streams_raw":
        from .streams_raw import StreamsRawForm
        return StreamsRawForm
    if name == "registry_prime":
        from .registry_prime import RegistryPrimeForm
        return RegistryPrimeForm
    if name == "registry_prune":
        from .registry_prune import RegistryPruneForm
        return RegistryPruneForm
    return None
