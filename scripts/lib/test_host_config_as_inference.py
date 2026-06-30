"""Tests for the as-inference DaemonSet host-config wiring in host-config.py.

as-inference is the action-solver service (foundation.bot/has-as-inference
gated, default-off). It CONSUMES the world-model z_ref rings and PRODUCES
/as_action (consumed downstream by the WBC); it does NOT drive /desired, so —
like wm-inference — it is NOT in the positronic/locomotion/sonic exclusion
group and it co-schedules. The service is the image entrypoint → mounts-only
deployment target (no DEPLOYMENT_BASE_ARGS).

Covers:
  - has-as-inference is a registered node label (default "false").
  - has-as-inference is NOT in the /desired exclusion group.
  - images.as-inference / as-inference-models render (retag + repo-swap).
  - mounts render + target the right DaemonSet/ns/container.
  - validation accepts a mounts override.
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


@pytest.fixture()
def cfg_as_mounts() -> dict:
    return {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "as-inference": {
                "mounts": [
                    {"name": "as-debug", "host": "/data/as-debug", "container": "/as-debug"},
                ],
            },
        },
    }


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


def test_has_as_inference_label_registered():
    labels = {k: default for k, default, _ in hc.NODE_LABEL_REGISTRY}
    assert labels.get("foundation.bot/has-as-inference") == "false"


def test_as_inference_not_in_desired_exclusion_group(capsys):
    """as-inference feeds the WBC, doesn't drive /desired — enabling it
    alongside default-on positronic must produce no exclusion error."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "nodeLabels": {"foundation.bot/has-as-inference": "true"},
    }
    errors = _validate_errors(cfg, capsys)
    assert not any("mutually exclusive" in e for e in errors), errors


def test_as_images_local_registry_retag():
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "images": {
            "as-inference": {"image": "localhost:5443/as-inference:v1.0.0-beta.3"},
            "as-inference-models": {"image": "localhost:5443/as-inference-models:v1.0.0-beta.3"},
        },
    }
    out = _images_json(cfg)
    assert "localhost:5443/as-inference:v1.0.0-beta.3" in out
    assert "localhost:5443/as-inference-models:v1.0.0-beta.3" in out


def test_as_images_dockerhub_repo_swap():
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "images": {
            "as-inference": {"image": "foundationbot/as-inference:v1.0.0-beta.3"},
        },
    }
    out = _images_json(cfg)
    assert "localhost:5443/as-inference=foundationbot/as-inference:v1.0.0-beta.3" in out


def test_patch_targets_as_daemonset(cfg_as_mounts):
    patches = _core_patches(cfg_as_mounts)
    ours = [p for p in patches if p["target"]["name"] == "as-inference"]
    assert len(ours) == 1
    tgt = ours[0]["target"]
    assert tgt["kind"] == "DaemonSet"
    assert tgt["namespace"] == "positronic"
    doc = yaml.safe_load(ours[0]["patch"])
    assert doc["spec"]["template"]["spec"]["containers"][0]["name"] == "as-inference"


def test_mounts_render(cfg_as_mounts):
    ours = [p for p in _core_patches(cfg_as_mounts) if p["target"]["name"] == "as-inference"][0]
    doc = yaml.safe_load(ours["patch"])
    spec = doc["spec"]["template"]["spec"]
    assert {v["name"] for v in spec["volumes"]} == {"as-debug"}
    assert {m["mountPath"] for m in spec["containers"][0]["volumeMounts"]} == {"/as-debug"}


def test_validate_accepts_as_mounts(cfg_as_mounts, capsys):
    assert _validate_errors(cfg_as_mounts, capsys) == []
