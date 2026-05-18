"""Tests for the ``perf:`` block in host-config.py.

The block exposes the operator-facing toggles documented in plan
``~/.claude/plans/remotes-origin-sof-877-tracing-with-opts-glimmering-thunder.md``:

  perf:
    preset: tensorrt-fp16        # → ConfigMap PERF_PRESET
    tracing:
      enabled: true              # → PERF_TRACING_ENABLED ("1")
      backend: system            # → PERF_TRACING_BACKEND
      output: /trace/policy.pftrace
    targetNodes: [fossil_encoder, dma_policy]

Bootstrap phase 13 (deployments) consumes:
  - ``get perf.<dotted.path>`` for individual values (e.g. backend).
  - ``get-perf-configmap-json`` to render the override patch that
    overlays the positronic-perf ConfigMap with operator values.
  - ``get-perf-deployment-patch-json`` to render the strategic-merge
    patch that adds /tmp/perfetto-{producer,consumer} hostPath mounts
    and ``fsGroup: 2026`` to positronic-control — emitted only when
    ``perf.tracing.backend == "system"``.

Tests load the host-config.py module directly (sibling import) and
exercise the public ``cmd_*`` functions.
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
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


# ----------------------------------------------------------------------
# Fixtures — minimal host-configs covering the perf-block surface.
# ----------------------------------------------------------------------


@pytest.fixture
def cfg_no_perf() -> dict:
    """Baseline host-config with no perf block at all."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}, "operator": {"enabled": True}},
    }


@pytest.fixture
def cfg_perf_full() -> dict:
    """Host-config with every perf field set."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}},
        "perf": {
            "preset": "tensorrt-fp16",
            "tracing": {
                "enabled": True,
                "backend": "system",
                "output": "/trace/policy.pftrace",
            },
            "targetNodes": ["fossil_encoder", "dma_policy"],
        },
    }


@pytest.fixture
def cfg_perf_in_process() -> dict:
    """Host-config with tracing enabled but in_process backend."""
    return {
        "robot": "mk09",
        "stacks": {"core": {}},
        "perf": {
            "preset": "inductor",
            "tracing": {
                "enabled": True,
                "backend": "in_process",
            },
        },
    }


# ----------------------------------------------------------------------
# get perf.<dotted.path>
# ----------------------------------------------------------------------


def test_get_perf_preset(cfg_perf_full, capsys):
    rc = hc.cmd_get_perf(cfg_perf_full, "preset")
    assert rc == 0
    assert capsys.readouterr().out.strip() == "tensorrt-fp16"


def test_get_perf_tracing_enabled(cfg_perf_full, capsys):
    rc = hc.cmd_get_perf(cfg_perf_full, "tracing.enabled")
    assert rc == 0
    assert capsys.readouterr().out.strip() in ("1", "true", "True")


def test_get_perf_tracing_backend(cfg_perf_full, capsys):
    rc = hc.cmd_get_perf(cfg_perf_full, "tracing.backend")
    assert rc == 0
    assert capsys.readouterr().out.strip() == "system"


def test_get_perf_tracing_output(cfg_perf_full, capsys):
    rc = hc.cmd_get_perf(cfg_perf_full, "tracing.output")
    assert rc == 0
    assert capsys.readouterr().out.strip() == "/trace/policy.pftrace"


def test_get_perf_missing_block_returns_1(cfg_no_perf):
    """No perf block at all: exit 1, no stdout."""
    rc = hc.cmd_get_perf(cfg_no_perf, "preset")
    assert rc == 1


def test_get_perf_missing_field_returns_1(cfg_perf_in_process):
    """Perf block present, field absent: exit 1."""
    # cfg_perf_in_process omits perf.tracing.output and perf.targetNodes
    rc = hc.cmd_get_perf(cfg_perf_in_process, "tracing.output")
    assert rc == 1


# ----------------------------------------------------------------------
# get-perf-configmap-json — emits {key: stringified-value} for envFrom
# ----------------------------------------------------------------------


def test_perf_configmap_patch_full(cfg_perf_full, capsys):
    rc = hc.cmd_get_perf_configmap_json(cfg_perf_full)
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["PERF_PRESET"] == "tensorrt-fp16"
    assert out["PERF_TRACING_ENABLED"] == "1"
    assert out["PERF_TRACING_BACKEND"] == "system"
    assert out["PERF_TRACING_OUTPUT"] == "/trace/policy.pftrace"
    assert out["PERF_TARGET_NODES"] == "fossil_encoder,dma_policy"


def test_perf_configmap_patch_in_process_no_target_nodes(cfg_perf_in_process, capsys):
    rc = hc.cmd_get_perf_configmap_json(cfg_perf_in_process)
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["PERF_PRESET"] == "inductor"
    assert out["PERF_TRACING_ENABLED"] == "1"
    assert out["PERF_TRACING_BACKEND"] == "in_process"
    # targetNodes omitted → key should not appear (operator gets the
    # ConfigMap default from manifests/base/positronic/perf-config.yaml)
    assert "PERF_TARGET_NODES" not in out


def test_perf_configmap_patch_empty_when_no_perf_block(cfg_no_perf, capsys):
    """No perf block → empty dict → ConfigMap defaults stay intact."""
    rc = hc.cmd_get_perf_configmap_json(cfg_no_perf)
    assert rc == 0
    assert json.loads(capsys.readouterr().out) == {}


# ----------------------------------------------------------------------
# get-perf-deployment-patch-json — emits hostPath socket mounts +
# fsGroup when backend=system, otherwise empty.
# ----------------------------------------------------------------------


def test_perf_deployment_patch_system_backend(cfg_perf_full, capsys):
    rc = hc.cmd_get_perf_deployment_patch_json(cfg_perf_full)
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    # Shape: {target: {kind, name, namespace}, patch: <yaml-str>}
    assert out["target"]["name"] == "positronic-control"
    assert out["target"]["kind"] == "DaemonSet"
    assert out["target"]["namespace"] == "positronic"
    patch_yaml = out["patch"]
    # fsGroup 2026 must be in the patch (pinned per the plan)
    assert "fsGroup: 2026" in patch_yaml
    # Both sockets must be mounted
    assert "/tmp/perfetto-producer" in patch_yaml
    assert "/tmp/perfetto-consumer" in patch_yaml


def test_perf_deployment_patch_in_process_backend(cfg_perf_in_process, capsys):
    """in_process backend doesn't need host sockets → empty patch payload."""
    rc = hc.cmd_get_perf_deployment_patch_json(cfg_perf_in_process)
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {}


def test_perf_deployment_patch_no_perf_block(cfg_no_perf, capsys):
    rc = hc.cmd_get_perf_deployment_patch_json(cfg_no_perf)
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {}


# ----------------------------------------------------------------------
# validate — reject malformed perf blocks
# ----------------------------------------------------------------------


def test_validate_accepts_perf_block(cfg_perf_full, capsys):
    rc = hc.cmd_validate(cfg_perf_full)
    assert rc == 0


def test_validate_rejects_unknown_backend(capsys):
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}},
        "perf": {"tracing": {"backend": "gibberish"}},
    }
    rc = hc.cmd_validate(cfg)
    assert rc != 0
    err = capsys.readouterr().err
    assert "backend" in err.lower()


def test_validate_rejects_non_bool_tracing_enabled(capsys):
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}},
        "perf": {"tracing": {"enabled": "yes"}},
    }
    rc = hc.cmd_validate(cfg)
    assert rc != 0


def test_validate_rejects_non_list_target_nodes(capsys):
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}},
        "perf": {"targetNodes": "fossil_encoder,dma_policy"},
    }
    rc = hc.cmd_validate(cfg)
    assert rc != 0
    err = capsys.readouterr().err
    assert "targetNodes" in err
