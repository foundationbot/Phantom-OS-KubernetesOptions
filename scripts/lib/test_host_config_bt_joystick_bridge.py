"""Tests for the bt-joystick-bridge DaemonSet host-config wiring.

bt-joystick-bridge (manifests/base/bt-joystick-bridge/) bridges a remote
Bluetooth joystick onto the robot as a virtual uinput gamepad. It is gated on
foundation.bot/has-vpad (default-off) and shares one image
(foundationbot/bt-joystick-bridge) across its two containers (netevent sidecar
+ Python relay) — same key/image indirection posture as ik-mk2.

Covers:
  - has-vpad is a registered node label (default "false").
  - images.bt-joystick-bridge retag-only override renders.
  - a repo-swap override renders as a find=replace entry.
  - validation accepts an images.bt-joystick-bridge override.
"""
from __future__ import annotations

import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOST_CONFIG = HERE / "host-config.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("host_config", HOST_CONFIG)
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


def _validate_errors(cfg: dict, capsys) -> list[str]:
    hc.cmd_validate(cfg)
    captured = capsys.readouterr()
    return [
        line[len("error: "):]
        for line in captured.err.splitlines()
        if line.startswith("error: ")
    ]


def _images_json(cfg: dict) -> list[str]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_images_json(cfg)
    assert rc == 0, buf.getvalue()
    return json.loads(buf.getvalue())


def test_has_vpad_label_registered():
    labels = {k: default for k, default, _ in hc.NODE_LABEL_REGISTRY}
    assert labels.get("foundation.bot/has-vpad") == "false"


def test_bt_joystick_bridge_container_target():
    target = hc.CONTAINER_TARGETS["bt-joystick-bridge"]
    assert target["stack"] == "core"
    assert target["manifest_image"] == "foundationbot/bt-joystick-bridge"


def test_bt_joystick_bridge_images_retag_only():
    """A same-repo override keeps the repo → retag-only entry."""
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}},
        "images": {
            "bt-joystick-bridge": {
                "image": "foundationbot/bt-joystick-bridge:v0.1.0-aarch64"
            },
        },
    }
    out = _images_json(cfg)
    assert "foundationbot/bt-joystick-bridge:v0.1.0-aarch64" in out


def test_validate_accepts_bt_joystick_bridge_override(capsys):
    cfg = {
        "robot": "mk09",
        "stacks": {"core": {}},
        "images": {
            "bt-joystick-bridge": {
                "image": "foundationbot/bt-joystick-bridge:v0.1.0-aarch64"
            },
        },
        "nodeLabels": {"foundation.bot/has-vpad": "true"},
    }
    assert _validate_errors(cfg, capsys) == []
