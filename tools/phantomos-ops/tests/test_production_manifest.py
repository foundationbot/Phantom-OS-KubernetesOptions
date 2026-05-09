"""Validate the shipped manifest.yaml.

This is the manifest the operator actually sees. It must always load
clean — any error here means the TUI ships with a broken entry.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from phantomos_ops import manifest as m


PROD_PATH = Path(__file__).resolve().parents[1] / "src" / "phantomos_ops" / "manifest.yaml"


def test_production_manifest_loads_without_errors():
    manifest, errors = m.load_manifest(PROD_PATH)
    assert errors == [], f"production manifest has errors: {errors}"
    # Shape sanity — these grow but never shrink to 0.
    assert len(manifest.groups) >= 6
    assert len(manifest.actions) >= 20


def test_every_action_has_an_existing_group():
    """Belt-and-braces: the loader already enforces this, but a manual
    check catches typos in the manifest before the loader runs."""
    manifest, _ = m.load_manifest(PROD_PATH)
    group_ids = {g.id for g in manifest.groups}
    for action in manifest.actions:
        assert action.group in group_ids, (
            f"action {action.id} references unknown group {action.group!r}"
        )


def test_every_red_action_has_a_confirm_word():
    manifest, _ = m.load_manifest(PROD_PATH)
    for a in manifest.actions:
        if a.safety == "red":
            assert a.confirm_word, f"red action {a.id} missing confirm_word"


def test_no_shell_string_commands():
    """Catch the most dangerous manifest mistake: a shell string in
    `command` instead of an argv list. The loader rejects this too,
    but we want a fast, explicit assertion in the production smoke
    test."""
    manifest, _ = m.load_manifest(PROD_PATH)
    for a in manifest.actions:
        assert isinstance(a.command, tuple)
        assert all(isinstance(s, str) for s in a.command)
        assert len(a.command) >= 1
