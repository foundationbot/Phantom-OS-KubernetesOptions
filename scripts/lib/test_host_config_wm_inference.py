"""Tests for the wm-inference DaemonSet host-config wiring in host-config.py.

wm-inference is the world-model z_ref service (foundation.bot/has-wm-inference
gated, default-off). It FEEDS positronic-control (z_ref provider) and is NOT in
the positronic/locomotion/sonic /desired mutual-exclusion group — it
co-schedules. The service is the image entrypoint, so there is no args override
(no DEPLOYMENT_BASE_ARGS entry) — the deployment target is mounts-only.

Covers:
  - has-wm-inference is a registered node label (default "false").
  - has-wm-inference is NOT in the /desired mutual-exclusion group (it can be
    enabled alongside default-on positronic without a validation error).
  - images.wm-inference / wm-inference-models render both as a local-registry
    retag and as a DockerHub repo-swap.
  - mounts render host-path volumes + volumeMounts on the wm-inference
    DaemonSet / positronic namespace / wm-inference container.
  - validation accepts a mounts override on wm-inference.
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
def cfg_wm_mounts() -> dict:
    """wm-inference with an extra per-robot host-path mount."""
    return {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "wm-inference": {
                "mounts": [
                    {"name": "wm-debug", "host": "/data/wm-debug", "container": "/wm-debug"},
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


def _images_json(cfg: dict) -> list[str]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_images_json(cfg)
    assert rc == 0
    return json.loads(buf.getvalue())


def _validate_errors(cfg: dict, capsys) -> list[str]:
    hc.cmd_validate(cfg)
    captured = capsys.readouterr()
    return [
        line[len("error: "):]
        for line in captured.err.splitlines()
        if line.startswith("error: ")
    ]


# ── registry tests ──────────────────────────────────────────────────────────


def test_has_wm_inference_label_registered():
    labels = {k: default for k, default, _ in hc.NODE_LABEL_REGISTRY}
    assert labels.get("foundation.bot/has-wm-inference") == "false"


def test_wm_inference_not_in_desired_exclusion_group(capsys):
    """wm-inference FEEDS positronic; it must be enable-able alongside the
    default-on positronic control brain with zero validation errors."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "nodeLabels": {
            "foundation.bot/has-wm-inference": "true",
            # positronic left implicit (defaults to "true") — this would be a
            # hard error for locomotion/sonic, but wm-inference is not in the
            # exclusion group.
        },
    }
    errors = _validate_errors(cfg, capsys)
    assert not any("mutually exclusive" in e for e in errors), errors


# ── image-override tests ──────────────────────────────────────────────────────


def test_wm_images_local_registry_retag():
    """localhost:5443 retag-only keeps the repo, just changes the tag."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "images": {
            "wm-inference": {"image": "localhost:5443/wm-inference:v1.0.0-beta.4"},
            "wm-inference-models": {"image": "localhost:5443/wm-inference-models:v1.0.0-beta.4"},
        },
    }
    out = _images_json(cfg)
    assert "localhost:5443/wm-inference:v1.0.0-beta.4" in out
    assert "localhost:5443/wm-inference-models:v1.0.0-beta.4" in out


def test_wm_images_dockerhub_repo_swap():
    """A DockerHub ref swaps the repo: 'manifest_image=repo:tag'."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "images": {
            "wm-inference": {"image": "foundationbot/wm-inference:v1.0.0-beta.4"},
        },
    }
    out = _images_json(cfg)
    assert "localhost:5443/wm-inference=foundationbot/wm-inference:v1.0.0-beta.4" in out


# ── patch-rendering tests ─────────────────────────────────────────────────────


def test_patch_targets_wm_daemonset(cfg_wm_mounts):
    patches = _core_patches(cfg_wm_mounts)
    ours = [p for p in patches if p["target"]["name"] == "wm-inference"]
    assert len(ours) == 1
    tgt = ours[0]["target"]
    assert tgt["kind"] == "DaemonSet"
    assert tgt["namespace"] == "positronic"
    doc = yaml.safe_load(ours[0]["patch"])
    assert doc["spec"]["template"]["spec"]["containers"][0]["name"] == "wm-inference"


def test_mounts_render(cfg_wm_mounts):
    ours = [p for p in _core_patches(cfg_wm_mounts) if p["target"]["name"] == "wm-inference"][0]
    doc = yaml.safe_load(ours["patch"])
    spec = doc["spec"]["template"]["spec"]
    assert {v["name"] for v in spec["volumes"]} == {"wm-debug"}
    assert {m["mountPath"] for m in spec["containers"][0]["volumeMounts"]} == {"/wm-debug"}


# ── validation tests ──────────────────────────────────────────────────────────


def test_validate_accepts_wm_mounts(cfg_wm_mounts, capsys):
    assert _validate_errors(cfg_wm_mounts, capsys) == []
