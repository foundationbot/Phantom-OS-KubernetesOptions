"""Tests for the okvis2x DaemonSet host-config wiring in host-config.py.

okvis2x is OKVIS2-X live dense-stereo SLAM (has-okvis gated, default-off).
Unlike cpp-robot-state-estimator (where extraArgs APPENDS flags), okvis2x's
argv is POSITIONAL (<app> <okvis.yaml> <se2.yaml> <output>), so
DEPLOYMENT_BASE_ARGS["okvis2x"] is empty and extraArgs is used as a WHOLESALE
argv replacement. The base manifest ships the real default (baked Thor config).

Covers:
  - has-okvis is a registered node label (default "false").
  - images.okvis2x / images.okvis2x-models retag-only overrides render.
  - extraArgs renders args == extraArgs verbatim (empty base) and targets the
    okvis2x DaemonSet / okvis namespace / okvis2x container.
  - mounts render host-path volumes + volumeMounts.
  - validation accepts extraArgs on okvis2x.
"""
from __future__ import annotations

import importlib.util
import io
import json
from contextlib import redirect_stdout
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


# ── fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture()
def cfg_okvis_full() -> dict:
    """okvis2x with a per-robot config mount + persistent output + full argv."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "okvis2x": {
                "mounts": [
                    {"name": "okvis-config", "host": "/etc/phantomos/okvis", "container": "/etc/okvis"},
                    {"name": "output", "host": "/data/okvis", "container": "/output"},
                ],
                "extraArgs": [
                    "dma_live",
                    "/etc/okvis/okvis_stereo_dense_thor.yaml",
                    "/etc/okvis/se2.yaml",
                    "/output",
                ],
            },
        },
    }


# ── helpers ───────────────────────────────────────────────────────────────────


def _core_patches(cfg: dict) -> list[dict]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_deployment_patches_json(cfg)
    assert rc == 0
    data = json.loads(buf.getvalue())
    for entry in data:
        if entry["stack"] == "core":
            return entry["patches"]
    return []


def _validate_errors(cfg: dict, capsys) -> list[str]:
    hc.cmd_validate(cfg)
    captured = capsys.readouterr()
    return [
        line[len("error: "):]
        for line in captured.err.splitlines()
        if line.startswith("error: ")
    ]


# ── registry tests ──────────────────────────────────────────────────────────


def test_has_okvis_label_registered():
    labels = {k: default for k, default, _ in hc.NODE_LABEL_REGISTRY}
    assert labels.get("foundation.bot/has-okvis") == "false"


def test_okvis_images_retag_only():
    """images.okvis2x / okvis2x-models keep their repo → retag-only entries."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "images": {
            "okvis2x": {"image": "foundationbot/okvis2x:thor-v1.2.3"},
            "okvis2x-models": {"image": "foundationbot/okvis2x-models:mdl-abc123"},
        },
    }
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_images_json(cfg)
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert "foundationbot/okvis2x:thor-v1.2.3" in out
    assert "foundationbot/okvis2x-models:mdl-abc123" in out


def test_okvis_base_args_empty():
    """extraArgs is a wholesale argv replacement → empty base."""
    assert hc.DEPLOYMENT_BASE_ARGS["okvis2x"] == []


# ── patch-rendering tests ─────────────────────────────────────────────────────


def test_extra_args_is_full_argv(cfg_okvis_full):
    """With an empty base, the rendered args equal extraArgs verbatim."""
    patches = _core_patches(cfg_okvis_full)
    ours = [p for p in patches if p["target"]["name"] == "okvis2x"]
    assert len(ours) == 1
    doc = yaml.safe_load(ours[0]["patch"])
    container = doc["spec"]["template"]["spec"]["containers"][0]
    assert container["args"] == [
        "dma_live",
        "/etc/okvis/okvis_stereo_dense_thor.yaml",
        "/etc/okvis/se2.yaml",
        "/output",
    ]


def test_patch_targets_okvis_daemonset(cfg_okvis_full):
    patches = _core_patches(cfg_okvis_full)
    ours = [p for p in patches if p["target"]["name"] == "okvis2x"]
    assert len(ours) == 1
    tgt = ours[0]["target"]
    assert tgt["kind"] == "DaemonSet"
    assert tgt["namespace"] == "positronic"
    doc = yaml.safe_load(ours[0]["patch"])
    assert doc["spec"]["template"]["spec"]["containers"][0]["name"] == "okvis2x"


def test_mounts_render(cfg_okvis_full):
    patches = _core_patches(cfg_okvis_full)
    ours = [p for p in patches if p["target"]["name"] == "okvis2x"][0]
    doc = yaml.safe_load(ours["patch"])
    spec = doc["spec"]["template"]["spec"]
    vol_names = {v["name"] for v in spec["volumes"]}
    assert vol_names == {"okvis-config", "output"}
    mount_paths = {m["mountPath"] for m in spec["containers"][0]["volumeMounts"]}
    assert mount_paths == {"/etc/okvis", "/output"}


# ── validation tests ──────────────────────────────────────────────────────────


def test_validate_accepts_okvis_extra_args(cfg_okvis_full, capsys):
    assert _validate_errors(cfg_okvis_full, capsys) == []
