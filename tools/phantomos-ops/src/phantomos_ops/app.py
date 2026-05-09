"""Top-level Textual App.

Thin shell — the heavy lifting is in screens/. Holds the manifest +
runtime services so screens can read them without globals.
"""
from __future__ import annotations

from importlib.resources import files
from pathlib import Path

from textual.app import App

from .manifest import SAMPLE_MANIFEST, Manifest
from .screens.main import MainScreen


def _theme_path() -> str:
    """Resolve theme.tcss for both editable and wheel installs."""
    return str(Path(__file__).with_name("theme.tcss"))


class OpsApp(App):
    """phantomos ops — TUI launcher."""

    CSS_PATH = _theme_path()
    TITLE = "phantomos ops"
    SUB_TITLE = "fleet operator launcher"

    def __init__(self, manifest: Manifest | None = None):
        super().__init__()
        self.manifest = manifest or SAMPLE_MANIFEST

    def on_mount(self) -> None:
        self.push_screen(MainScreen(self.manifest))
