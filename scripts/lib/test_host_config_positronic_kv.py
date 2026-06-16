"""Tests for cmd_get_positronic_config_kv in host-config.py.

positronic_control's diagnostic launch mode mirrors phantom-locomotion's
`mode: diagnostic`, driven from a separate `positronicControl`
host-config block. This extraction emits the POSITRONIC_MODE +
POSITRONIC_DIAGNOSTIC_* env set (and the diagnostic PHANTOM_CMD) that the
positronic-config ConfigMap delivers to the DaemonSet via envFrom.

Tests load the host-config.py module directly (sibling import) and
exercise the public cmd_get_positronic_config_kv function, asserting on
the emitted KEY=VALUE lines.
"""
from __future__ import annotations

import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
HOST_CONFIG = HERE / "host-config.py"


def _load_module():
    """Import scripts/lib/host-config.py despite the hyphen in the name."""
    spec = importlib.util.spec_from_file_location("host_config", HOST_CONFIG)
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


# ── helpers ──────────────────────────────────────────────────────────────────


def _kv(cfg: dict) -> dict[str, str]:
    """Run cmd_get_positronic_config_kv and parse the KEY=VALUE lines."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_positronic_config_kv(cfg)
    assert rc == 0, buf.getvalue()
    out: dict[str, str] = {}
    for line in buf.getvalue().splitlines():
        if not line:
            continue
        key, _, value = line.partition("=")
        out[key] = value
    return out


def _err_rc(cfg: dict, capsys) -> int:
    rc = hc.cmd_get_positronic_config_kv(cfg)
    return rc


# ── production mode ────────────────────────────────────────────────────────────


def test_absent_block_defaults_to_production():
    """No positronicControl block -> POSITRONIC_MODE=production only."""
    kv = _kv({"robot": "mk09"})
    assert kv == {"POSITRONIC_MODE": "production"}


def test_explicit_production_emits_mode_only_no_phantom_cmd():
    """Production mode never clobbers the FIR-407/408 PHANTOM_CMD path."""
    kv = _kv({"positronicControl": {"mode": "production"}})
    assert kv == {"POSITRONIC_MODE": "production"}
    assert "PHANTOM_CMD" not in kv


# ── diagnostic mode ────────────────────────────────────────────────────────────


def test_diagnostic_defaults_merged_and_phantom_cmd():
    """Bare `mode: diagnostic` emits the full default knob set + launcher."""
    kv = _kv({"positronicControl": {"mode": "diagnostic"}})
    assert kv["POSITRONIC_MODE"] == "diagnostic"
    # PHANTOM_CMD flips the pod into the diagnostic launcher.
    assert kv["PHANTOM_CMD"] == hc.POSITRONIC_DIAGNOSTIC_LAUNCHER
    assert kv["PHANTOM_CMD"] == "bash /src/docker/positronic_diagnostic_launch.sh"
    # Defaults merged in from DEFAULT_POSITRONIC_DIAGNOSTIC.
    assert kv["POSITRONIC_DIAGNOSTIC_ROBOT"] == "mk2-lower-body"
    assert kv["POSITRONIC_DIAGNOSTIC_NAMING"] == "mj"
    assert kv["POSITRONIC_DIAGNOSTIC_BIAS"] == "0.10"
    assert kv["POSITRONIC_DIAGNOSTIC_MASTER_GAIN"] == "0.3"
    assert (
        kv["POSITRONIC_DIAGNOSTIC_OUT_PATH"]
        == "/recordings/diag_reports/diag_report.json"
    )
    assert kv["POSITRONIC_DIAGNOSTIC_WAIT_FOR_START"] == "true"


def test_diagnostic_tol_to_band_splitting():
    """A single tol knob expands to a LO/HI band pair (1±tol)."""
    kv = _kv(
        {
            "positronicControl": {
                "mode": "diagnostic",
                "diagnostic": {"velTrackingRatioTol": "0.30"},
            }
        }
    )
    assert kv["POSITRONIC_DIAGNOSTIC_VEL_TRACKING_RATIO_BAND_LO"] == "0.7"
    assert kv["POSITRONIC_DIAGNOSTIC_VEL_TRACKING_RATIO_BAND_HI"] == "1.3"
    # The raw tol field is NOT emitted directly.
    assert "POSITRONIC_DIAGNOSTIC_VEL_TRACKING_RATIO_TOL" not in kv


def test_diagnostic_override_merges_on_defaults():
    """Operator override replaces one field; the rest keep defaults."""
    kv = _kv(
        {
            "positronicControl": {
                "mode": "diagnostic",
                "diagnostic": {"bias": "0.20", "masterGain": "0.5"},
            }
        }
    )
    assert kv["POSITRONIC_DIAGNOSTIC_BIAS"] == "0.20"
    assert kv["POSITRONIC_DIAGNOSTIC_MASTER_GAIN"] == "0.5"
    # Unset fields keep their defaults.
    assert kv["POSITRONIC_DIAGNOSTIC_NAMING"] == "mj"


def test_diagnostic_bool_coercion():
    """YAML bool waitForStart -> lowercase string for the bash check."""
    kv = _kv(
        {
            "positronicControl": {
                "mode": "diagnostic",
                "diagnostic": {"waitForStart": False},
            }
        }
    )
    assert kv["POSITRONIC_DIAGNOSTIC_WAIT_FOR_START"] == "false"


def test_diagnostic_omit_if_empty():
    """Empty jointBiasOverrides is omitted, not emitted as KEY=."""
    kv = _kv({"positronicControl": {"mode": "diagnostic"}})
    assert "POSITRONIC_DIAGNOSTIC_JOINT_BIAS_OVERRIDES" not in kv
    assert "POSITRONIC_DIAGNOSTIC_CHIRP_AMPLITUDE_OVERRIDES" not in kv


# ── validation ──────────────────────────────────────────────────────────────


def test_invalid_mode_rejected():
    rc = hc.cmd_get_positronic_config_kv(
        {"positronicControl": {"mode": "bogus"}}
    )
    assert rc == 2


def test_unknown_diagnostic_field_rejected():
    rc = hc.cmd_get_positronic_config_kv(
        {
            "positronicControl": {
                "mode": "diagnostic",
                "diagnostic": {"notARealKnob": "1"},
            }
        }
    )
    assert rc == 2


def test_positronic_defaults_match_locomotion():
    """The positronic diagnostic defaults are a 1:1 clone of locomotion."""
    assert hc.DEFAULT_POSITRONIC_DIAGNOSTIC == hc.DEFAULT_LOCOMOTION_DIAGNOSTIC
    # Field->env maps differ only by prefix.
    for field, env in hc.POSITRONIC_DIAGNOSTIC_FIELD_TO_ENV.items():
        assert env == hc.DIAGNOSTIC_FIELD_TO_ENV[field].replace(
            "LOCOMOTION_", "POSITRONIC_", 1
        )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
