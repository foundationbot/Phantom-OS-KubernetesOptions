"""Tests for the YAML manifest loader.

Loader contract:
- Returns (manifest, errors). errors is a list of human-readable
  strings — empty when the file is fully valid.
- Bad individual entries are dropped from the returned manifest with
  one error string each, NOT raised. This lets the TUI boot and
  surface the problem in a startup banner.
- Truly catastrophic input (file missing, invalid YAML, top-level
  shape wrong) raises ManifestError — the app still has to handle
  this but at least it's a single failure mode.
"""
from __future__ import annotations

from textwrap import dedent

import pytest

from phantomos_ops import manifest as m


def write(tmp_path, body: str):
    p = tmp_path / "manifest.yaml"
    p.write_text(dedent(body))
    return p


def test_loads_minimal_valid_file(tmp_path):
    f = write(tmp_path, """
        groups:
          - id: workloads
            title: "Workloads"
            order: 1
        actions:
          - id: positronic.status
            group: workloads
            title: "Show what positronic-control is doing right now"
            blurb: "Read-only snapshot."
            safety: green
            command: ["bash", "scripts/positronic.sh", "status"]
    """)
    manifest, errors = m.load_manifest(f)
    assert errors == []
    assert len(manifest.groups) == 1
    assert len(manifest.actions) == 1
    a = manifest.actions[0]
    assert a.id == "positronic.status"
    assert a.safety == "green"
    assert a.command == ("bash", "scripts/positronic.sh", "status")


def test_unknown_group_drops_action_with_error(tmp_path):
    f = write(tmp_path, """
        groups:
          - id: workloads
            title: "Workloads"
            order: 1
        actions:
          - id: x.y
            group: typo_group
            title: "X"
            blurb: "Y"
            safety: green
            command: ["true"]
    """)
    manifest, errors = m.load_manifest(f)
    assert len(manifest.actions) == 0
    assert any("typo_group" in e for e in errors)


def test_missing_required_field_drops_action(tmp_path):
    """An action without a title is unrenderable; it gets dropped."""
    f = write(tmp_path, """
        groups:
          - id: g
            title: "G"
            order: 1
        actions:
          - id: bad
            group: g
            blurb: "no title here"
            safety: green
            command: ["true"]
    """)
    manifest, errors = m.load_manifest(f)
    assert len(manifest.actions) == 0
    assert any("title" in e for e in errors)


def test_invalid_safety_class_drops_action(tmp_path):
    f = write(tmp_path, """
        groups:
          - id: g
            title: "G"
            order: 1
        actions:
          - id: bad
            group: g
            title: "Bad"
            blurb: "blurb"
            safety: "purple"
            command: ["true"]
    """)
    manifest, errors = m.load_manifest(f)
    assert len(manifest.actions) == 0
    assert any("safety" in e and "purple" in e for e in errors)


def test_red_action_requires_confirm_word(tmp_path):
    """Red actions without confirm_word are a manifest bug — drop."""
    f = write(tmp_path, """
        groups:
          - id: g
            title: "G"
            order: 1
        actions:
          - id: nuke
            group: g
            title: "Nuke it"
            blurb: "kaboom"
            safety: red
            command: ["true"]
    """)
    manifest, errors = m.load_manifest(f)
    assert len(manifest.actions) == 0
    assert any("confirm_word" in e for e in errors)


def test_command_must_be_list_not_string(tmp_path):
    """A shell-string command opens injection holes when forms feed
    user values in. Reject it loudly."""
    f = write(tmp_path, """
        groups:
          - id: g
            title: "G"
            order: 1
        actions:
          - id: bad
            group: g
            title: "Shell injection waiting to happen"
            blurb: "oops"
            safety: green
            command: "bash scripts/foo.sh"
    """)
    manifest, errors = m.load_manifest(f)
    assert len(manifest.actions) == 0
    assert any("command" in e and "list" in e for e in errors)


def test_duplicate_action_ids_dropped(tmp_path):
    """Action ids are stable contracts (favorites, run <id>, persisted
    form values). A duplicate is unsafe — keep first, drop rest."""
    f = write(tmp_path, """
        groups:
          - id: g
            title: "G"
            order: 1
        actions:
          - id: dup
            group: g
            title: "First"
            blurb: "first"
            safety: green
            command: ["true"]
          - id: dup
            group: g
            title: "Second"
            blurb: "second"
            safety: green
            command: ["true"]
    """)
    manifest, errors = m.load_manifest(f)
    assert len(manifest.actions) == 1
    assert manifest.actions[0].title == "First"
    assert any("duplicate" in e.lower() for e in errors)


def test_invalid_yaml_raises(tmp_path):
    f = write(tmp_path, "groups: [\n  - id: x\n    title:")
    with pytest.raises(m.ManifestError):
        m.load_manifest(f)


def test_missing_file_raises(tmp_path):
    with pytest.raises(m.ManifestError):
        m.load_manifest(tmp_path / "nope.yaml")


def test_top_level_shape_wrong(tmp_path):
    """No top-level groups + actions = catastrophic — raise."""
    f = write(tmp_path, "just_a_string_no_keys")
    with pytest.raises(m.ManifestError):
        m.load_manifest(f)


def test_optional_fields_have_sensible_defaults(tmp_path):
    f = write(tmp_path, """
        groups:
          - id: g
            title: "G"
            order: 1
        actions:
          - id: a
            group: g
            title: "A"
            blurb: "blurb"
            safety: green
            command: ["true"]
    """)
    manifest, errors = m.load_manifest(f)
    a = manifest.actions[0]
    assert a.requires == ()
    assert a.runs_on == ("robot", "dev")
    assert a.duration == ""
    assert a.reversible is True
    assert a.confirm_word == ""
    assert a.dry_run is None
    assert a.form is None
