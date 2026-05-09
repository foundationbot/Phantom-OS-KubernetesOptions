"""Top-level Textual App.

Thin shell — the heavy lifting is in screens/. Holds the manifest +
runtime services so screens can read them without globals.
"""
from __future__ import annotations

from pathlib import Path

from textual.app import App

from .manifest import SAMPLE_MANIFEST, Manifest, ManifestError, load_manifest
from .screens.main import MainScreen


def _theme_path() -> str:
    """Resolve theme.tcss for both editable and wheel installs."""
    return str(Path(__file__).with_name("theme.tcss"))


def _default_manifest_path() -> Path:
    return Path(__file__).with_name("manifest.yaml")


class OpsApp(App):
    """phantomos ops — TUI launcher."""

    CSS_PATH = _theme_path()
    TITLE = "phantomos ops"
    SUB_TITLE = "fleet operator launcher"

    def __init__(self, manifest: Manifest | None = None):
        super().__init__()
        # Errors collected at boot — surfaced in M3's startup banner.
        # For now we keep them on the app so the run-screen can show
        # them when the operator opens the help overlay.
        self.manifest_errors: list[str] = []

        if manifest is not None:
            self.manifest = manifest
        else:
            try:
                loaded, errors = load_manifest(_default_manifest_path())
                self.manifest = loaded
                self.manifest_errors = errors
            except ManifestError as exc:
                # Catastrophic load failure — fall back to the in-tree
                # SAMPLE_MANIFEST so the app still boots and shows an
                # error rather than crashing on launch.
                self.manifest = SAMPLE_MANIFEST
                self.manifest_errors = [f"manifest load failed: {exc}"]

    def on_mount(self) -> None:
        self.push_screen(MainScreen(self.manifest))
