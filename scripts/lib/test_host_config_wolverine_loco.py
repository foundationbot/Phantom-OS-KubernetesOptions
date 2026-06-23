"""Tests for the wolverine-loco DaemonSet host-config wiring in host-config.py.

wolverine-loco is the MK2 whole-body velocity-locomotion workload
(foundation.bot/has-wolverine-loco gated, default-off): a pure-C++ 1 kHz
inference node + a teleop web-UI sidecar. It DRIVES /desired, so — unlike
wm-inference / as-inference — it IS in the positronic/locomotion/sonic mutual
exclusion group. Its node + policies + teleop images are DockerHub images
(foundationbot/*), host-configurable via the images: block.

Covers:
  - has-wolverine-loco is a registered node label (default "false").
  - has-wolverine-loco IS in the /desired exclusion group (conflicts with the
    default-on positronic, and with locomotion/sonic).
  - has-wolverine-loco alone (positronic explicitly off) validates clean.
  - images.wolverine-{dma-inference-cpp,policies,teleop} render (DockerHub
    repo-swap retag).
"""
from __future__ import annotations

import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
HOST_CONFIG = HERE / "host-config.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("host_config", HOST_CONFIG)
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


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


def test_has_wolverine_loco_label_registered():
    labels = {k: default for k, default, _ in hc.NODE_LABEL_REGISTRY}
    assert labels.get("foundation.bot/has-wolverine-loco") == "false"


def test_wolverine_loco_in_desired_exclusion_group_vs_positronic(capsys):
    """wolverine-loco drives /desired — enabling it while positronic is left
    implicitly default-on must error (and point at disabling positronic)."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "nodeLabels": {"foundation.bot/has-wolverine-loco": "true"},
    }
    errors = _validate_errors(cfg, capsys)
    assert any(
        "foundation.bot/has-positronic" in e and "wolverine-loco" in e
        for e in errors
    ), errors


def test_wolverine_loco_conflicts_with_locomotion(capsys):
    """Two explicit /desired drivers (wolverine-loco + locomotion, positronic
    off) is the generic mutual-exclusion error."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "nodeLabels": {
            "foundation.bot/has-positronic": "false",
            "foundation.bot/has-locomotion": "true",
            "foundation.bot/has-wolverine-loco": "true",
        },
    }
    errors = _validate_errors(cfg, capsys)
    assert any("mutually exclusive" in e for e in errors), errors


def test_wolverine_loco_alone_validates_clean(capsys):
    """wolverine-loco enabled with positronic explicitly off (and the other
    drivers off) is a valid single-driver config."""
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "nodeLabels": {
            "foundation.bot/has-positronic": "false",
            "foundation.bot/has-wolverine-loco": "true",
        },
    }
    errors = _validate_errors(cfg, capsys)
    assert not any("mutually exclusive" in e for e in errors), errors


def test_wolverine_images_not_host_configurable(capsys):
    """The three wolverine-loco images share ONE DockerHub repo
    (foundationbot/dma-ghost-wbc-inference, tag-prefixed), so Kustomize's
    by-name override can't retag them independently — they are PINNED in the
    base manifest and intentionally NOT registered in CONTAINER_TARGETS. A host
    listing one under images: must fail loud as an unknown container."""
    assert "wolverine-dma-inference-cpp" not in hc.CONTAINER_TARGETS
    assert "wolverine-policies" not in hc.CONTAINER_TARGETS
    assert "wolverine-teleop" not in hc.CONTAINER_TARGETS
    assert "dma-ghost-wbc-inference" not in hc.CONTAINER_TARGETS

    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}, "operator": {}},
        "images": {"dma-ghost-wbc-inference": {"image": "foundationbot/dma-ghost-wbc-inference:v0.1.0"}},
    }
    rc = hc.cmd_get_images_json(cfg)
    captured = capsys.readouterr()
    assert rc == 2
    assert "unknown container" in captured.err
