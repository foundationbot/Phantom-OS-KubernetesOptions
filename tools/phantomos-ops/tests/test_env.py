"""Tests for the env probe.

Each capability returns a Detection (`available: bool`, `detail: str`).
The probe never raises — missing tools / unreadable files are
modelled as available=False with a human-readable detail.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from phantomos_ops import env


def test_fingerprint_returns_dataclass(monkeypatch, tmp_path):
    """Fingerprint always returns a populated Fingerprint regardless of env."""
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", tmp_path / "missing")
    monkeypatch.setattr(env, "_which", lambda _: None)

    fp = env.fingerprint(refresh=True)

    assert isinstance(fp, env.Fingerprint)
    assert fp.host  # always populated from socket.gethostname
    assert fp.robot_id == ""  # missing file → empty, not None or raise
    assert fp.kubectl.available is False
    assert fp.kubectl.detail  # always has a reason string


def test_robot_id_read_from_file(monkeypatch, tmp_path):
    """robot_id reads /etc/phantomos/robot when present."""
    f = tmp_path / "robot"
    f.write_text("hwthor01\n")
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", f)
    monkeypatch.setattr(env, "_which", lambda _: None)

    fp = env.fingerprint(refresh=True)
    assert fp.robot_id == "hwthor01"


def test_kubectl_prefers_plain_over_k0s(monkeypatch, tmp_path):
    """When both kubectl and k0s exist, the probe picks plain kubectl."""
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", tmp_path / "missing")
    monkeypatch.setattr(env, "_which",
                        lambda name: f"/usr/bin/{name}" if name in ("kubectl", "k0s") else None)

    fp = env.fingerprint(refresh=True)
    assert fp.kubectl.available is True
    assert "kubectl" in fp.kubectl.detail
    assert "k0s" not in fp.kubectl.detail


def test_kubectl_falls_back_to_k0s(monkeypatch, tmp_path):
    """k0s kubectl is used when plain kubectl is missing."""
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", tmp_path / "missing")
    monkeypatch.setattr(env, "_which",
                        lambda name: "/usr/bin/k0s" if name == "k0s" else None)

    fp = env.fingerprint(refresh=True)
    assert fp.kubectl.available is True
    assert "k0s" in fp.kubectl.detail


def test_capability_check_known_keys(monkeypatch, tmp_path):
    """has_capability covers every requires: token the manifest can use."""
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", tmp_path / "missing")
    monkeypatch.setattr(env, "_which", lambda _: None)

    fp = env.fingerprint(refresh=True)
    # Unknown capability → False, never raises (manifest typos shouldn't crash).
    assert fp.has_capability("does_not_exist") is False
    # Known capabilities accept lookup.
    assert fp.has_capability("kubectl") is False  # we mocked kubectl missing
    assert fp.has_capability("root") in {True, False}  # don't assume test runner uid


def test_memoization_returns_same_instance(monkeypatch, tmp_path):
    """Two calls within the cache TTL return the same dataclass instance."""
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", tmp_path / "missing")
    monkeypatch.setattr(env, "_which", lambda _: None)

    a = env.fingerprint(refresh=True)
    b = env.fingerprint()  # no refresh — should hit cache
    assert a is b


def test_refresh_returns_new_instance(monkeypatch, tmp_path):
    """refresh=True bypasses cache."""
    monkeypatch.setattr(env, "_ROBOT_ID_PATH", tmp_path / "missing")
    monkeypatch.setattr(env, "_which", lambda _: None)

    a = env.fingerprint(refresh=True)
    b = env.fingerprint(refresh=True)
    assert a is not b
