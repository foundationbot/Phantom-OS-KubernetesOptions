"""Tests for the policy-diagnostics DIAG_* render in host-config.py.

policy-diagnostics is the standalone diagnostic workload
(manifests/base/policy-diagnostics/policy-diagnostics.yaml): a DaemonSet
whose launcher (policy-diagnostics-tools' launch.py) reads the generic
DIAG_* env namespace from the policy-diagnostics-config ConfigMap (envFrom,
optional:true). host-config renders that ConfigMap from the
phantomPolicyDiagnostics block via `get-policy-diagnostics-config-kv`.

Unlike the locomotion render (LOCOMOTION_DIAGNOSTIC_*, which PRE-EXPANDS
tol fields into BAND_LO/BAND_HI pairs), this render emits RAW values — the
launcher does its own band math + CSV splitting. So it is a straight
field->DIAG_* map.

Covers:
  - bare config emits the DIAG_* defaults (one per DEFAULT_POLICY_DIAGNOSTICS
    field minus the omit-if-empty knobs), with bools lowercased and tol
    fields emitted raw (no BAND_LO/BAND_HI).
  - a phantomPolicyDiagnostics block with the 14 gain fields renders the
    DIAG_* gain envs (globals + override CSVs), and empty override lists
    are omitted.
  - every DIAG_FIELD_TO_ENV name + value round-trips: launch.py consumes it.
  - the new gain defaults do NOT leak into the locomotion render.
  - validate accepts/rejects phantomPolicyDiagnostics shapes.
"""
from __future__ import annotations

import importlib.util
import io
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


def _diag_kv(cfg: dict) -> dict[str, str]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_policy_diagnostics_config_kv(cfg)
    assert rc == 0, buf.getvalue()
    out: dict[str, str] = {}
    for line in buf.getvalue().splitlines():
        if not line:
            continue
        key, _, value = line.partition("=")
        out[key] = value
    return out


def _loco_kv(cfg: dict) -> dict[str, str]:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_phantom_locomotion_config_kv(cfg)
    assert rc == 0, buf.getvalue()
    out: dict[str, str] = {}
    for line in buf.getvalue().splitlines():
        if not line:
            continue
        key, _, value = line.partition("=")
        out[key] = value
    return out


def _validate_errors(cfg: dict, capsys) -> list[str]:
    hc.cmd_validate(cfg)
    captured = capsys.readouterr()
    return [
        line[len("error: "):]
        for line in captured.err.splitlines()
        if line.startswith("error: ")
    ]


def test_defaults_emit_diag_envs_no_block():
    """A config with no phantomPolicyDiagnostics block emits the DIAG_*
    defaults — one line per field except the omit-if-empty knobs (whose
    default is "")."""
    kv = _diag_kv({})
    # Scalar defaults straight from launch.py's _PASSTHROUGH / file knobs.
    assert kv["DIAG_ROBOT"] == "mk2-lower-body"
    assert kv["DIAG_BIAS"] == "0.10"
    assert kv["DIAG_MASTER_GAIN"] == "0.3"
    assert kv["DIAG_ITERATIONS"] == "1"
    assert kv["DIAG_TEST_MODE"] == "joint-sweep"
    assert kv["DIAG_MJ_ORDER_FILE"] == "/etc/policy-diagnostics-tools/mj_order.json"
    assert kv["DIAG_IMU_ROLES_FILE"] == "/etc/policy-diagnostics-tools/imu_roles.json"
    # Bool fields render lowercase for launch.py's `== "true"` checks.
    assert kv["DIAG_WAIT_FOR_START"] == "true"
    assert kv["DIAG_SKIP_IMU_TESTS"] == "false"
    # All seven gain globals default to 0.0 (= inherit CSP).
    for env in ("DIAG_POSITION_KP", "DIAG_POSITION_KI", "DIAG_POSITION_KD",
                "DIAG_VELOCITY_KP", "DIAG_VELOCITY_KI", "DIAG_VELOCITY_KD",
                "DIAG_TORQUE_KP"):
        assert kv[env] == "0.0", env
    # Empty-by-default override / optional knobs are omitted entirely.
    for env in ("DIAG_POSITION_KP_OVERRIDES", "DIAG_JOINT_BIAS_OVERRIDES",
                "DIAG_RETURN_RAMP_S", "DIAG_MJ_ORDER_FROM_CONFIG"):
        assert env not in kv, env


def test_tol_fields_emit_raw_not_band():
    """The launcher does its own band math, so the tol fields must render as
    a single raw DIAG_*_TOL value — NOT pre-expanded BAND_LO/BAND_HI."""
    kv = _diag_kv({})
    assert kv["DIAG_VEL_TRACKING_RATIO_TOL"] == "0.30"
    assert kv["DIAG_GRAVITY_MAG_TOL"] == "0.05"
    assert kv["DIAG_IMU_PITCH_RATIO_TOL"] == "0.30"
    # No band envs should be emitted anywhere in this render.
    assert not any("BAND_LO" in k or "BAND_HI" in k for k in kv), kv


def test_gain_block_renders_globals_and_overrides():
    """A phantomPolicyDiagnostics block setting the 14 gain fields renders
    the DIAG_* gain envs; non-empty override CSVs pass through raw (the
    launcher splits them), empty override lists are omitted."""
    cfg = {
        "phantomPolicyDiagnostics": {
            "positionKp": "150.0",
            "velocityKd": "2.5",
            "torqueKp": "0.8",
            "positionKpOverrides": "LeftKnee=200.0,RightKnee=200.0",
            "torqueKpOverrides": "LeftAnkleRoll=0.5",
        }
    }
    kv = _diag_kv(cfg)
    assert kv["DIAG_POSITION_KP"] == "150.0"
    assert kv["DIAG_VELOCITY_KD"] == "2.5"
    assert kv["DIAG_TORQUE_KP"] == "0.8"
    # Untouched gains keep their inherit-CSP default.
    assert kv["DIAG_POSITION_KI"] == "0.0"
    # Non-empty override CSVs emit raw (no splitting at this layer).
    assert kv["DIAG_POSITION_KP_OVERRIDES"] == "LeftKnee=200.0,RightKnee=200.0"
    assert kv["DIAG_TORQUE_KP_OVERRIDES"] == "LeftAnkleRoll=0.5"
    # Override lists left at their "" default are omitted.
    assert "DIAG_POSITION_KI_OVERRIDES" not in kv
    assert "DIAG_VELOCITY_KP_OVERRIDES" not in kv


def test_every_field_maps_to_a_diag_env():
    """Every field in DEFAULT_POLICY_DIAGNOSTICS has a DIAG_FIELD_TO_ENV
    entry, and the maps agree on the key set (no orphan envs)."""
    assert set(hc.DEFAULT_POLICY_DIAGNOSTICS) == set(hc.DIAG_FIELD_TO_ENV)
    # Every emitted env name starts with DIAG_.
    assert all(v.startswith("DIAG_") for v in hc.DIAG_FIELD_TO_ENV.values())


def test_gains_do_not_leak_into_locomotion_render():
    """Adding the 14 gain defaults to the shared diagnostic dict must not
    emit any DIAG_*/gain env from the locomotion render (no LOCOMOTION_
    DIAGNOSTIC_* mapping for them)."""
    kv = _loco_kv({"phantomLocomotion": {"mode": "diagnostic"}})
    assert not any("POSITION_KP" in k or "TORQUE_KP" in k
                   or "VELOCITY_KP" in k for k in kv), kv
    # chirpRrdDir IS a locomotion knob (emitted there) but NOT a policy-
    # diagnostics one (launch.py has no DIAG_CHIRP_RRD_DIR).
    assert "LOCOMOTION_DIAGNOSTIC_CHIRP_RRD_DIR" in kv
    assert "chirpRrdDir" not in hc.DEFAULT_POLICY_DIAGNOSTICS


def test_validate_accepts_policy_diagnostics_block(capsys):
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "phantomPolicyDiagnostics": {
            "positionKp": 150.0,
            "skipImuTests": True,
            "positionKpOverrides": "LeftKnee=200.0",
        },
    }
    errors = _validate_errors(cfg, capsys)
    assert not any("phantomPolicyDiagnostics" in e for e in errors), errors


def test_validate_rejects_unknown_field(capsys):
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "phantomPolicyDiagnostics": {"bogusField": "x"},
    }
    errors = _validate_errors(cfg, capsys)
    assert any("phantomPolicyDiagnostics" in e and "bogusField" in e
               for e in errors), errors


def test_validate_rejects_non_scalar(capsys):
    cfg = {
        "robot": "ch4",
        "stacks": {"core": {}},
        "phantomPolicyDiagnostics": {"positionKpOverrides": ["a", "b"]},
    }
    errors = _validate_errors(cfg, capsys)
    assert any("phantomPolicyDiagnostics.positionKpOverrides" in e
               for e in errors), errors


def test_unknown_field_in_kv_errors():
    cfg = {"phantomPolicyDiagnostics": {"nope": "1"}}
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_policy_diagnostics_config_kv(cfg)
    assert rc == 2
