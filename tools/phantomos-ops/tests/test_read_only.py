"""Read-only mode and single-instance lock."""
from __future__ import annotations

from pathlib import Path

import pytest

from phantomos_ops.app import OpsApp, _filter_read_only
from phantomos_ops.manifest import Action, Group, Manifest


def _mixed_manifest() -> Manifest:
    return Manifest(
        groups=(
            Group("read", "Read-only stuff", order=1),
            Group("write", "Write stuff", order=2),
            Group("danger", "Dangerous stuff", order=3),
        ),
        actions=(
            Action(id="read.a", group="read", title="Read A",
                   blurb="x", safety="green", command=("true",)),
            Action(id="write.a", group="write", title="Write A",
                   blurb="x", safety="yellow", command=("true",)),
            Action(id="danger.a", group="danger", title="Danger A",
                   blurb="x", safety="red", confirm_word="ok",
                   command=("true",)),
        ),
    )


def test_read_only_filter_keeps_only_green():
    full = _mixed_manifest()
    safe = _filter_read_only(full)
    assert all(a.safety == "green" for a in safe.actions)
    assert len(safe.actions) == 1


def test_read_only_drops_groups_with_no_visible_actions():
    """A group whose entries are all yellow/red should disappear from
    the left pane — empty groups would be misleading."""
    full = _mixed_manifest()
    safe = _filter_read_only(full)
    group_ids = {g.id for g in safe.groups}
    assert "read" in group_ids
    assert "write" not in group_ids
    assert "danger" not in group_ids


def test_read_only_app_construction_propagates_filter():
    app = OpsApp(manifest=_mixed_manifest(), read_only=True)
    assert all(a.safety == "green" for a in app.manifest.actions)


def test_lock_acquires_when_free(tmp_path):
    from phantomos_ops.lock import InstanceLock
    p = tmp_path / "lock"
    with InstanceLock(p) as lock:
        assert lock.acquired
        assert p.exists()


def test_lock_detects_existing_holder(tmp_path):
    """Second attempt while the first is held returns acquired=False."""
    from phantomos_ops.lock import InstanceLock
    p = tmp_path / "lock"
    with InstanceLock(p) as first:
        assert first.acquired
        with InstanceLock(p) as second:
            assert second.acquired is False


def test_lock_released_after_exit(tmp_path):
    """Re-acquire after exit must succeed — no stale lock."""
    from phantomos_ops.lock import InstanceLock
    p = tmp_path / "lock"
    with InstanceLock(p) as first:
        assert first.acquired
    with InstanceLock(p) as second:
        assert second.acquired
