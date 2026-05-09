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


def _filter_read_only(manifest: Manifest) -> Manifest:
    """Strip yellow + red actions for --read-only mode.

    Demo / over-the-shoulder use: the operator wants to walk through
    the menu without risk of fat-fingering anything that mutates state.
    Groups whose actions are all gone get dropped from the left pane
    too, so the UI doesn't mislead with empty groups.
    """
    safe = tuple(a for a in manifest.actions if a.safety == "green")
    used_groups = {a.group for a in safe}
    groups = tuple(g for g in manifest.groups if g.id in used_groups)
    return Manifest(groups=groups, actions=safe)


class OpsApp(App):
    """phantomos ops — TUI launcher."""

    CSS_PATH = _theme_path()
    TITLE = "phantomos ops"
    SUB_TITLE = "fleet operator launcher"

    def __init__(self, manifest: Manifest | None = None,
                 read_only: bool = False):
        super().__init__()
        # Errors collected at boot — surfaced in M3's startup banner.
        self.manifest_errors: list[str] = []
        # Per-session confirmation memory: action ids the operator has
        # already confirmed. Cleared on quit. Per-action, never global.
        self.confirmed_this_session: set[str] = set()
        self.read_only = read_only

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

        if self.read_only:
            self.manifest = _filter_read_only(self.manifest)

    def on_mount(self) -> None:
        self.push_screen(MainScreen(self.manifest))
