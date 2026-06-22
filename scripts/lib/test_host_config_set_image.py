"""Tests for the `set-image` setter in host-config.py (Component B of the
2026-06-22 offline image-tarball provisioning design).

`set-image <container> <ref>` writes images.<container>.image in place,
preserving comments / formatting (no yaml.dump round-trip). Covers the three
insert cases (no images: block / block-without-key / key-already-present), the
validation rejections (unknown container, non-local ref on a local-only
container), and a get-image-for-container round-trip after each successful set.
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

HERE = Path(__file__).resolve().parent
HOST_CONFIG = HERE / "host-config.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("host_config", HOST_CONFIG)
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


# ── helpers ───────────────────────────────────────────────────────────────────


def _run(path: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(HOST_CONFIG), str(path), *args],
        capture_output=True,
        text=True,
    )


def _set_image(path: Path, container: str, ref: str) -> subprocess.CompletedProcess:
    return _run(path, "set-image", container, ref)


def _get_image(path: Path, container: str) -> str:
    cp = _run(path, "get-image-for-container", container)
    assert cp.returncode == 0, cp.stderr
    return cp.stdout.strip()


def _images(path: Path) -> dict:
    cfg = yaml.safe_load(path.read_text()) or {}
    return cfg.get("images") or {}


# ── case (c): no images: block at all ──────────────────────────────────────────


def test_case_c_no_images_block_creates_one_and_preserves_comments(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    cfg.write_text(
        "# top-of-file comment\n"
        "robot: mk09\n"
        "stacks:\n"
        "  core: {}\n"
        "  # an inline comment inside stacks\n"
        "  operator: {}\n"
    )
    ref = "localhost:5443/phantom-models:2026-06-08"
    cp = _set_image(cfg, "phantom-models", ref)
    assert cp.returncode == 0, cp.stderr

    text = cfg.read_text()
    # images block created, value present.
    assert _images(cfg)["phantom-models"]["image"] == ref
    # pre-existing comments preserved verbatim.
    assert "# top-of-file comment" in text
    assert "# an inline comment inside stacks" in text
    # round-trip via the reader.
    assert _get_image(cfg, "phantom-models") == ref
    # trailing newline preserved.
    assert text.endswith("\n")


# ── case (b): images: block exists without the key ─────────────────────────────


def test_case_b_inserts_without_disturbing_existing_entry(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    cfg.write_text(
        "robot: mk09\n"
        "images:\n"
        "  # operator-ui pinned to a CI sha\n"
        "  operator-ui:\n"
        "    image: foundationbot/argus.operator-ui:abc123\n"
        "nodeLabels:\n"
        "  foundation.bot/has-okvis: 'false'\n"
    )
    ref = "localhost:5443/phantom-policies:2026-06-08"
    cp = _set_image(cfg, "phantom-policies", ref)
    assert cp.returncode == 0, cp.stderr

    images = _images(cfg)
    # new entry added.
    assert images["phantom-policies"]["image"] == ref
    # pre-existing operator-ui untouched.
    assert images["operator-ui"]["image"] == "foundationbot/argus.operator-ui:abc123"
    text = cfg.read_text()
    assert "# operator-ui pinned to a CI sha" in text
    # trailing block (nodeLabels) not clobbered.
    assert "nodeLabels:" in text
    assert _get_image(cfg, "phantom-policies") == ref
    assert _get_image(cfg, "operator-ui") == "foundationbot/argus.operator-ui:abc123"


# ── case (a): key already present ──────────────────────────────────────────────


def test_case_a_replaces_existing_value(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    cfg.write_text(
        "robot: mk09\n"
        "images:\n"
        "  phantom-models:\n"
        "    image: localhost:5443/phantom-models:2026-01-01\n"
        "  operator-ui:\n"
        "    image: foundationbot/argus.operator-ui:abc123\n"
    )
    new_ref = "localhost:5443/phantom-models:2026-06-08"
    cp = _set_image(cfg, "phantom-models", new_ref)
    assert cp.returncode == 0, cp.stderr

    images = _images(cfg)
    assert images["phantom-models"]["image"] == new_ref
    # neighbour entry untouched.
    assert images["operator-ui"]["image"] == "foundationbot/argus.operator-ui:abc123"
    assert _get_image(cfg, "phantom-models") == new_ref


# ── rejections ─────────────────────────────────────────────────────────────────


def test_rejects_unknown_container(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    original = "robot: mk09\n"
    cfg.write_text(original)
    cp = _set_image(cfg, "not-a-real-container", "localhost:5443/x:1")
    assert cp.returncode != 0
    assert "unknown container" in cp.stderr
    # file unchanged.
    assert cfg.read_text() == original


def test_rejects_non_local_ref_for_local_only_container(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    original = (
        "robot: mk09\n"
        "images:\n"
        "  phantom-models:\n"
        "    image: localhost:5443/phantom-models:2026-01-01\n"
    )
    cfg.write_text(original)
    cp = _set_image(cfg, "phantom-models", "foundationbot/x:1")
    assert cp.returncode != 0
    assert "local-registry-only" in cp.stderr
    # file unchanged.
    assert cfg.read_text() == original


def test_rejects_ref_without_tag(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    original = "robot: mk09\n"
    cfg.write_text(original)
    cp = _set_image(cfg, "phantom-models", "localhost:5443/phantom-models")
    assert cp.returncode != 0
    assert cfg.read_text() == original


def test_non_local_only_container_accepts_dockerhub_ref(tmp_path):
    """operator-ui is NOT local-registry-only — a foundationbot/* ref is OK."""
    cfg = tmp_path / "host-config.yaml"
    cfg.write_text("robot: mk09\n")
    ref = "foundationbot/argus.operator-ui:deadbeef"
    cp = _set_image(cfg, "operator-ui", ref)
    assert cp.returncode == 0, cp.stderr
    assert _get_image(cfg, "operator-ui") == ref


def test_usage_error_on_missing_args(tmp_path):
    cfg = tmp_path / "host-config.yaml"
    cfg.write_text("robot: mk09\n")
    cp = _run(cfg, "set-image", "phantom-models")
    assert cp.returncode != 0
    assert "usage:" in cp.stderr
