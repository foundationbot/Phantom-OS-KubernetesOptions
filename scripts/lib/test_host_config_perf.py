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


# ----------------------------------------------------------------------
# Integration with cmd_get_deployment_patches_json — the perf patches
# must surface inside the core-stack patches list so phase 13 wiring
# picks them up automatically.
# ----------------------------------------------------------------------


def test_deployment_patches_includes_perf_configmap_patch(cfg_perf_full, capsys):
    rc = hc.cmd_get_deployment_patches_json(cfg_perf_full)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    targets = [p["target"]["name"] for p in core["patches"]]
    assert "positronic-perf" in targets, (
        f"expected positronic-perf ConfigMap patch in core stack; got: {targets}"
    )
    cm_patch = next(
        p for p in core["patches"] if p["target"]["name"] == "positronic-perf"
    )
    assert cm_patch["target"]["kind"] == "ConfigMap"
    assert "PERF_PRESET: tensorrt-fp16" in cm_patch["patch"]


def test_deployment_patches_includes_perf_deployment_patch_when_system_backend(
    cfg_perf_full, capsys
):
    rc = hc.cmd_get_deployment_patches_json(cfg_perf_full)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    # The positronic-control entry should now include the hostPath
    # socket mounts and fsGroup from the perf-deployment patch.
    pc = [p for p in core["patches"] if p["target"]["name"] == "positronic-control"]
    assert len(pc) == 1, (
        f"expected exactly one positronic-control patch; got {len(pc)}"
    )
    assert "fsGroup: 2026" in pc[0]["patch"]
    assert "/tmp/perfetto-producer" in pc[0]["patch"]


def test_deployment_patches_no_perf_deployment_when_in_process(
    cfg_perf_in_process, capsys
):
    rc = hc.cmd_get_deployment_patches_json(cfg_perf_in_process)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    pc = [p for p in core["patches"] if p["target"]["name"] == "positronic-control"]
    # in_process backend: no positronic-control patch from perf (only
    # the ConfigMap patch with PERF_* values). When deployments: block
    # is absent there should be no entry at all.
    if pc:
        assert "fsGroup: 2026" not in pc[0]["patch"]
        assert "/tmp/perfetto-producer" not in pc[0]["patch"]


def test_deployment_patches_no_perf_anywhere_when_no_perf_block(
    cfg_no_perf, capsys
):
    rc = hc.cmd_get_deployment_patches_json(cfg_no_perf)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    targets = [p["target"]["name"] for p in core["patches"]]
    assert "positronic-perf" not in targets
    pc = [p for p in core["patches"] if p["target"]["name"] == "positronic-control"]
    # No perf, no deployments overrides → no positronic-control patch.
    assert pc == []


# ----------------------------------------------------------------------
# dmaVideo schema — switch dma-video producer to video-playback mode
# for recorded-video benchmarks (the SOF-877 testing flow on k0s).
# ----------------------------------------------------------------------


@pytest.fixture
def cfg_video_playback() -> dict:
    return {
        "robot": "ch4",
        "stacks": {"core": {}},
        "dmaVideo": {
            "producer": {
                "mode": "video",
                "file": "/home/phantom/foundation/positronic_control/videos/test.mp4",
                "numCameras": 1,
                "fps": 25,
                "format": "nv12",
            },
        },
    }


def test_video_producer_patch_emits_video_args(cfg_video_playback, capsys):
    rc = hc.cmd_get_deployment_patches_json(cfg_video_playback)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    prod = [
        p for p in core["patches"]
        if p["target"]["name"] == "producer"
        and p["target"]["namespace"] == "dma-video"
    ]
    assert len(prod) == 1, (
        f"expected exactly one dma-video producer patch; got {len(prod)}"
    )
    patch = prod[0]["patch"]
    # Args switch to the `video` subcommand. The container sees the
    # video at /videos/<basename>; the host directory is bind-mounted
    # at /videos via a hostPath volume (see the mount test below).
    assert "- video" in patch
    assert "/videos/test.mp4" in patch
    assert "--num-cameras" in patch
    assert "--fps" in patch
    assert "--format" in patch
    assert "nv12" in patch


def test_video_producer_patch_mounts_video_file(cfg_video_playback, capsys):
    """The video file's parent directory must be mounted into the pod."""
    rc = hc.cmd_get_deployment_patches_json(cfg_video_playback)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    prod = next(
        p for p in core["patches"]
        if p["target"]["name"] == "producer"
        and p["target"]["namespace"] == "dma-video"
    )
    patch = prod["patch"]
    assert "/home/phantom/foundation/positronic_control/videos" in patch


def test_no_video_producer_patch_when_mode_camera(capsys):
    """mode != "video" → no producer patch (default camera manifest stands)."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "dmaVideo": {"producer": {"mode": "camera"}},
    }
    rc = hc.cmd_get_deployment_patches_json(cfg)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    prod = [
        p for p in core["patches"]
        if p["target"]["name"] == "producer"
        and p["target"]["namespace"] == "dma-video"
    ]
    assert prod == []


def test_no_video_producer_patch_when_dmavideo_absent(capsys):
    rc = hc.cmd_get_deployment_patches_json({"robot": "ch4", "stacks": {"core": {}}})
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    core = next(e for e in data if e["stack"] == "core")
    prod = [
        p for p in core["patches"]
        if p["target"]["name"] == "producer"
        and p["target"]["namespace"] == "dma-video"
    ]
    assert prod == []


def test_validate_rejects_video_mode_without_file(capsys):
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "dmaVideo": {"producer": {"mode": "video"}},
    }
    rc = hc.cmd_validate(cfg)
    assert rc != 0
    err = capsys.readouterr().err
    assert "file" in err.lower()


def test_validate_rejects_unknown_mode(capsys):
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "dmaVideo": {"producer": {"mode": "gibberish", "file": "/tmp/x.mp4"}},
    }
    rc = hc.cmd_validate(cfg)
    assert rc != 0
    err = capsys.readouterr().err
    assert "mode" in err.lower()


def test_validate_rejects_unknown_format(capsys):
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "dmaVideo": {
            "producer": {
                "mode": "video",
                "file": "/tmp/x.mp4",
                "format": "h264",
            },
        },
    }
    rc = hc.cmd_validate(cfg)
    assert rc != 0
    err = capsys.readouterr().err
    assert "format" in err.lower()
