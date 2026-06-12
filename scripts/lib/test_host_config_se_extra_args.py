"""Tests for deployments.cpp-robot-state-estimator.extraArgs in host-config.py.

extraArgs is a generic append-only argv escape hatch for the SE DaemonSet.
The motivating case is robots without F/T sensors (e.g. mk11000009) that
need --foot-contact-source kinematic instead of the default ft_sensors
contact source.

Design:
  - When set, the rendered patch sets the container args =
    DEPLOYMENT_BASE_ARGS["cpp-robot-state-estimator"] + extraArgs.
  - When absent, no SE workload patch is emitted.
  - Only supported on cpp-robot-state-estimator; rejected elsewhere.
  - Must be a list of scalars; dicts/lists inside it are rejected.

Tests load the host-config.py module directly (sibling import) and
exercise the public cmd_* functions.
"""
from __future__ import annotations

import importlib.util
import io
import json
import sys
from contextlib import redirect_stdout
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
HOST_CONFIG = HERE / "host-config.py"


def _load_module():
    """Import scripts/lib/host-config.py despite the hyphen in the filename."""
    spec = importlib.util.spec_from_file_location("host_config", HOST_CONFIG)
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


# ── fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture()
def cfg_no_deployments() -> dict:
    """Baseline host-config with no deployments block at all."""
    return {"robot": "mk09", "stacks": {"core": {}, "operator": {}}}


@pytest.fixture()
def cfg_se_extra_args() -> dict:
    """Host-config with extraArgs on cpp-robot-state-estimator."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "cpp-robot-state-estimator": {
                "extraArgs": ["--foot-contact-source", "kinematic"],
            },
        },
    }


@pytest.fixture()
def cfg_se_extra_args_empty() -> dict:
    """Host-config with an empty extraArgs list — no patch should be emitted."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "cpp-robot-state-estimator": {
                "extraArgs": [],
            },
        },
    }


@pytest.fixture()
def cfg_se_no_extra_args() -> dict:
    """SE entry in deployments but no extraArgs — no workload patch."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "cpp-robot-state-estimator": {},
        },
    }


# ── helpers ───────────────────────────────────────────────────────────────────


def _get_patches(cfg: dict) -> list[dict]:
    """Run cmd_get_deployment_patches_json and return the parsed JSON list."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_deployment_patches_json(cfg)
    assert rc == 0
    return json.loads(buf.getvalue())


def _core_patches(cfg: dict) -> list[dict]:
    """Return only the core-stack patches from get-deployment-patches-json."""
    data = _get_patches(cfg)
    for entry in data:
        if entry["stack"] == "core":
            return entry["patches"]
    return []


def _validate_errors(cfg: dict, capsys) -> list[str]:
    """Run cmd_validate and return the list of 'error: ...' lines."""
    rc = hc.cmd_validate(cfg)
    captured = capsys.readouterr()
    errs = [
        line[len("error: "):]
        for line in captured.err.splitlines()
        if line.startswith("error: ")
    ]
    return errs


# ── patch-rendering tests ─────────────────────────────────────────────────────


def test_extra_args_patch_sets_full_args_list(cfg_se_extra_args):
    """extraArgs renders a DaemonSet patch whose args = base + extraArgs."""
    patches = _core_patches(cfg_se_extra_args)
    se_patches = [p for p in patches if p["target"]["name"] == "cpp-robot-state-estimator"]
    assert len(se_patches) == 1, "expected exactly one SE patch"

    import yaml
    doc = yaml.safe_load(se_patches[0]["patch"])
    containers = doc["spec"]["template"]["spec"]["containers"]
    assert len(containers) == 1
    args = containers[0]["args"]

    # Base args must be present verbatim
    base = list(hc.CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS)
    assert args[: len(base)] == base, f"base args missing or reordered: {args}"

    # extraArgs appended after base
    assert args[len(base):] == ["--foot-contact-source", "kinematic"]


def test_extra_args_patch_targets_correct_daemonset(cfg_se_extra_args):
    """Patch metadata matches the cpp-robot-state-estimator DaemonSet."""
    patches = _core_patches(cfg_se_extra_args)
    se_patches = [p for p in patches if p["target"]["name"] == "cpp-robot-state-estimator"]
    assert len(se_patches) == 1
    tgt = se_patches[0]["target"]
    assert tgt["kind"] == "DaemonSet"
    assert tgt["namespace"] == "positronic"


def test_extra_args_patch_container_name(cfg_se_extra_args):
    """Patch targets the 'state-estimator' container (not some other name)."""
    patches = _core_patches(cfg_se_extra_args)
    se_patches = [p for p in patches if p["target"]["name"] == "cpp-robot-state-estimator"]
    import yaml
    doc = yaml.safe_load(se_patches[0]["patch"])
    container = doc["spec"]["template"]["spec"]["containers"][0]
    assert container["name"] == "state-estimator"


def test_absent_extra_args_no_se_workload_patch(cfg_se_no_extra_args):
    """SE entry with no extraArgs (or other workload fields) → no patch emitted."""
    patches = _core_patches(cfg_se_no_extra_args)
    se_patches = [p for p in patches if p["target"]["name"] == "cpp-robot-state-estimator"]
    assert se_patches == [], "expected no SE patch when extraArgs absent"


def test_empty_extra_args_patch_has_no_args_override(cfg_se_extra_args_empty):
    """extraArgs: [] (empty list) → patch is emitted (key present in spec) but
    args are NOT overridden — the container_spec gains no 'args' key."""
    patches = _core_patches(cfg_se_extra_args_empty)
    se_patches = [p for p in patches if p["target"]["name"] == "cpp-robot-state-estimator"]
    # A patch IS emitted because the key is present in spec and matches
    # _WORKLOAD_PATCH_FIELDS. But it has no args override.
    assert len(se_patches) == 1
    import yaml
    doc = yaml.safe_load(se_patches[0]["patch"])
    container = doc["spec"]["template"]["spec"]["containers"][0]
    assert "args" not in container, (
        "empty extraArgs must not override args (no argv-overlay triggered)"
    )


def test_no_deployments_no_se_patch(cfg_no_deployments):
    """No deployments block → no SE patch at all."""
    patches = _core_patches(cfg_no_deployments)
    se_patches = [p for p in patches if p["target"]["name"] == "cpp-robot-state-estimator"]
    assert se_patches == []


# ── validation tests ──────────────────────────────────────────────────────────


def test_validate_accepts_extra_args_on_se(cfg_se_extra_args, capsys):
    """extraArgs on cpp-robot-state-estimator passes validation."""
    errs = _validate_errors(cfg_se_extra_args, capsys)
    assert errs == [], f"unexpected errors: {errs}"


def test_validate_rejects_extra_args_on_dma_recorder(capsys):
    """extraArgs on dma-recorder is rejected — not in EXTRA_ARGS_SUPPORTED_DEPLOYMENTS."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "dma-recorder": {
                "extraArgs": ["--something"],
            },
        },
    }
    errs = _validate_errors(cfg, capsys)
    assert any("extraArgs" in e for e in errs), (
        f"expected extraArgs rejection error, got: {errs}"
    )
    assert any("cpp-robot-state-estimator" in e for e in errs), (
        f"expected mention of supported deployments, got: {errs}"
    )


def test_validate_rejects_extra_args_on_rerun_streamer(capsys):
    """extraArgs on rerun-streamer is rejected."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "rerun-streamer": {
                "extraArgs": ["--something"],
            },
        },
    }
    errs = _validate_errors(cfg, capsys)
    assert any("extraArgs" in e for e in errs), (
        f"expected extraArgs rejection error, got: {errs}"
    )


def test_validate_rejects_non_list_extra_args(capsys):
    """extraArgs: 'a string' (not a list) → validation error."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "cpp-robot-state-estimator": {
                "extraArgs": "--foot-contact-source kinematic",
            },
        },
    }
    errs = _validate_errors(cfg, capsys)
    assert any("extraArgs" in e for e in errs), (
        f"expected non-list extraArgs error, got: {errs}"
    )


def test_validate_rejects_dict_element_in_extra_args(capsys):
    """extraArgs with a dict element (not a scalar) → validation error."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "cpp-robot-state-estimator": {
                "extraArgs": [{"key": "value"}],
            },
        },
    }
    errs = _validate_errors(cfg, capsys)
    assert any("extraArgs" in e for e in errs), (
        f"expected non-scalar element error, got: {errs}"
    )


def test_validate_rejects_list_element_in_extra_args(capsys):
    """extraArgs with a nested list element → validation error."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {}},
        "deployments": {
            "cpp-robot-state-estimator": {
                "extraArgs": [["nested"]],
            },
        },
    }
    errs = _validate_errors(cfg, capsys)
    assert any("extraArgs" in e for e in errs), (
        f"expected nested-list element error, got: {errs}"
    )


def test_base_args_match_manifest():
    """Guard the sync contract: CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS must equal the
    base manifest's container args:. extraArgs patches REPLACE args wholesale, so
    if these drift, every extraArgs-bearing robot silently runs a different SE
    arg set than the base manifest (the bug that snuck in a stray --mujoco-model,
    making the SE re-rotate IMU on top of DMA.ethercat's body-frame rotation)."""
    import yaml

    manifest = (
        HERE / ".." / ".." / "manifests" / "base"
        / "cpp-robot-state-estimator" / "state-estimator.yaml"
    ).resolve()
    doc = yaml.safe_load(manifest.read_text())
    containers = doc["spec"]["template"]["spec"]["containers"]
    se = next(c for c in containers if c["name"] == "state-estimator")
    manifest_args = [str(a) for a in se["args"]]

    assert manifest_args == list(hc.CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS), (
        "CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS drifted from the base manifest "
        f"args:. manifest={manifest_args} base_args="
        f"{list(hc.CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS)}"
    )
