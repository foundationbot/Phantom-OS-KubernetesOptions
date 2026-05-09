"""Repo-root discovery tests."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from phantomos_ops import repo


def _make_fake_repo(root: Path) -> Path:
    """Create a minimal directory tree that has the repo's marker."""
    marker = root / "manifests" / "stacks" / "core" / "kustomization.yaml"
    marker.parent.mkdir(parents=True)
    marker.write_text("# fake")
    return root


def test_env_var_wins(monkeypatch, tmp_path):
    fake = _make_fake_repo(tmp_path / "fleet")
    monkeypatch.setenv("PHANTOMOS_REPO", str(fake))
    monkeypatch.chdir(tmp_path)        # cwd is NOT a repo
    assert repo.find_repo_root() == fake.resolve()


def test_env_var_pointing_at_non_repo_falls_through(monkeypatch, tmp_path):
    monkeypatch.setenv("PHANTOMOS_REPO", str(tmp_path))   # no marker
    fake = _make_fake_repo(tmp_path / "real")
    monkeypatch.chdir(fake)
    assert repo.find_repo_root() == fake.resolve()


def test_walks_up_from_cwd(monkeypatch, tmp_path):
    monkeypatch.delenv("PHANTOMOS_REPO", raising=False)
    fake = _make_fake_repo(tmp_path / "checkout")
    deep = fake / "scripts" / "lib"
    deep.mkdir(parents=True)
    monkeypatch.chdir(deep)
    assert repo.find_repo_root() == fake.resolve()


def test_returns_none_when_nothing_matches(monkeypatch, tmp_path):
    monkeypatch.delenv("PHANTOMOS_REPO", raising=False)
    monkeypatch.chdir(tmp_path)
    # Stub _COMMON_PATHS so we don't hit a real /opt/... if it happens
    # to exist on the dev host.
    monkeypatch.setattr(repo, "_COMMON_PATHS", ())
    # Source-tree fallback would still find the actual repo we're
    # running in. Force `__file__` resolution to fail by stubbing.
    monkeypatch.setattr(repo, "find_repo_root",
                        repo.find_repo_root.__wrapped__
                        if hasattr(repo.find_repo_root, "__wrapped__")
                        else _force_no_source_fallback(repo))
    assert repo.find_repo_root() is None


def _force_no_source_fallback(mod):
    """Build a copy of find_repo_root that skips the source-tree
    fallback. Avoids monkeypatching __file__ which is brittle."""
    def _impl():
        env = os.environ.get("PHANTOMOS_REPO")
        if env:
            p = Path(env)
            if mod._is_repo(p):
                return p.resolve()
        found = mod._walk_up(Path.cwd())
        if found:
            return found
        for candidate in mod._COMMON_PATHS:
            p = Path(candidate)
            if mod._is_repo(p):
                return p.resolve()
        return None
    return _impl


def test_or_error_returns_message_when_missing(monkeypatch, tmp_path):
    monkeypatch.delenv("PHANTOMOS_REPO", raising=False)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(repo, "_COMMON_PATHS", ())
    monkeypatch.setattr(repo, "find_repo_root", lambda: None)
    root, err = repo.find_repo_root_or_error()
    assert root is None
    assert "PHANTOMOS_REPO" in err
    assert "checkout" in err


def test_or_error_returns_root_when_found(monkeypatch, tmp_path):
    fake = _make_fake_repo(tmp_path / "fleet")
    monkeypatch.setenv("PHANTOMOS_REPO", str(fake))
    monkeypatch.chdir(tmp_path)
    root, err = repo.find_repo_root_or_error()
    assert err is None
    assert root == fake.resolve()
