"""Tests for the two positronic-config kustomize-patch-merge python blocks
embedded in scripts/bootstrap-robot.sh.

The bootstrap delivers positronic-config to the core Argo Application as
two strategic-merge ConfigMap/positronic-config patches that must COEXIST:

  * phase 6.6 (positronic_config)            -> the env patch
        POSITRONIC_MODE + POSITRONIC_DIAGNOSTIC_* [+ diagnostic PHANTOM_CMD]
  * phase 12 (_patch_positronic_phantom_cmd) -> the production PHANTOM_CMD
        patch (read from deployments.positronic-control.launchCommand)

These blocks are heredoc'd bash, so to test them we slice each `python3 -
<<'PY' ... PY` body straight out of the bash source and run it with the
same env-var contract the bash sets up. Then we feed the phase-6.6 output
as phase-12's CURRENT_PATCHES (the real run order: 6.6 then 12) and assert
the acceptance criteria:

  1. diagnostic: both patches present; PHANTOM_CMD=launcher survives.
  2. production: POSITRONIC_MODE only from 6.6; PHANTOM_CMD=launchCommand
     from 12; both coexist.
  3. flip diagnostic->production reverts cleanly (no stale diagnostic env
     or diagnostic PHANTOM_CMD).
  4. both blocks parse and emit valid JSON.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

HERE = Path(__file__).resolve().parent
BOOTSTRAP = HERE.parent / "bootstrap-robot.sh"

LAUNCHER = "bash /src/docker/positronic_diagnostic_launch.sh"
PROD_CMD = "ros2 launch srg_localization phantom_launch.py"


def _slice_block(marker: str) -> str:
    """Return the python body of the heredoc whose opener contains marker.

    The opener may span lines (bash line-continuation), so find the marker
    line, then the next `<<'PY'`, then the matching closing `PY`.
    """
    lines = BOOTSTRAP.read_text().splitlines()
    mark_i = None
    for i, line in enumerate(lines):
        if marker in line:
            mark_i = i
            break
    assert mark_i is not None, f"opener with {marker!r} not found"
    start = None
    for i in range(mark_i, len(lines)):
        if "<<'PY'" in lines[i]:
            start = i + 1
            break
    assert start is not None, f"<<'PY' after {marker!r} not found"
    end = None
    for j in range(start, len(lines)):
        if lines[j].strip() == "PY":
            end = j
            break
    assert end is not None, "closing PY not found"
    return "\n".join(lines[start:end]) + "\n"


ENV_BLOCK = _slice_block('KV_TEXT="$kv_text" MODE="$mode"')
CMD_BLOCK = _slice_block('LAUNCH_COMMAND="$launch_command" FIELD_ABSENT=')


def _run(block: str, env: dict[str, str]) -> list[dict]:
    """Run a sliced python block; return the merged patches list."""
    proc = subprocess.run(
        [sys.executable, "-c", block],
        env={**os.environ, **env},
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)  # acceptance #4: valid JSON
    return doc["spec"]["source"]["kustomize"]["patches"]


def _env_patch(kv_text: str, mode: str, current: list) -> list[dict]:
    return _run(
        ENV_BLOCK,
        {
            "KV_TEXT": kv_text,
            "MODE": mode,
            "CURRENT_PATCHES": json.dumps(current),
        },
    )


def _cmd_patch(launch: str, field_absent: bool, current: list) -> list[dict]:
    return _run(
        CMD_BLOCK,
        {
            "LAUNCH_COMMAND": launch,
            "FIELD_ABSENT": "1" if field_absent else "0",
            "CURRENT_PATCHES": json.dumps(current),
        },
    )


def _data_of(patch: dict) -> dict:
    return yaml.safe_load(patch["patch"]).get("data", {})


def _find_env_patch(patches: list[dict]) -> dict | None:
    for p in patches:
        if "POSITRONIC_MODE" in (p.get("patch") or ""):
            return p
    return None


def _find_cmd_only_patch(patches: list[dict]) -> dict | None:
    for p in patches:
        body = p.get("patch") or ""
        if "PHANTOM_CMD" in body and "POSITRONIC_MODE" not in body:
            return p
    return None


# ── acceptance #1: diagnostic mode ──────────────────────────────────────────

DIAG_KV = (
    "POSITRONIC_MODE=diagnostic\n"
    "POSITRONIC_DIAGNOSTIC_ROBOT=mk2-lower-body\n"
    "POSITRONIC_DIAGNOSTIC_VEL_TRACKING_RATIO_TOL=0.30\n"
    f"PHANTOM_CMD={LAUNCHER}\n"
)


def test_diagnostic_full_run_order():
    # phase 6.6 first (empty cluster patches), then phase 12 on top.
    after_66 = _env_patch(DIAG_KV, "diagnostic", [])
    # In diagnostic mode phase 12 is forced into scrub mode (field_absent).
    after_12 = _cmd_patch("", field_absent=True, current=after_66)

    env = _find_env_patch(after_12)
    assert env is not None, "env patch must survive phase 12 (BUG 3)"
    data = _data_of(env)
    assert data["POSITRONIC_MODE"] == "diagnostic"
    assert data["POSITRONIC_DIAGNOSTIC_ROBOT"] == "mk2-lower-body"
    assert data["POSITRONIC_DIAGNOSTIC_VEL_TRACKING_RATIO_TOL"] == "0.30"
    # PHANTOM_CMD=launcher lives in the env patch and reaches the pod (BUG 2).
    assert data["PHANTOM_CMD"] == LAUNCHER
    # No separate production PHANTOM_CMD-only patch present.
    assert _find_cmd_only_patch(after_12) is None


# ── acceptance #2: production mode ──────────────────────────────────────────

PROD_KV = "POSITRONIC_MODE=production\n"


def test_production_full_run_order():
    after_66 = _env_patch(PROD_KV, "production", [])
    env = _find_env_patch(after_66)
    data = _data_of(env)
    assert data == {"POSITRONIC_MODE": "production"}
    assert "PHANTOM_CMD" not in data  # 6.6 doesn't own it in production.

    # phase 12: launchCommand present -> emits the production PHANTOM_CMD.
    after_12 = _cmd_patch(PROD_CMD, field_absent=False, current=after_66)
    env = _find_env_patch(after_12)
    assert _data_of(env) == {"POSITRONIC_MODE": "production"}  # untouched
    cmd = _find_cmd_only_patch(after_12)
    assert cmd is not None
    assert _data_of(cmd) == {"PHANTOM_CMD": PROD_CMD}
    # Both patches coexist: env patch not stripped by phase 12 (BUG 3 guard).
    assert len([p for p in after_12]) == 2


# ── acceptance #3: clean revert diagnostic -> production ─────────────────────


def test_flip_diagnostic_to_production_reverts():
    # Start from a cluster that already has a diagnostic env patch (with
    # launcher PHANTOM_CMD) from a prior diagnostic run.
    diag = _env_patch(DIAG_KV, "diagnostic", [])
    diag = _cmd_patch("", field_absent=True, current=diag)
    assert _data_of(_find_env_patch(diag))["PHANTOM_CMD"] == LAUNCHER

    # Now flip to production: phase 6.6 rewrites its env patch (mode only),
    # phase 12 owns PHANTOM_CMD from launchCommand.
    after_66 = _env_patch(PROD_KV, "production", diag)
    env = _find_env_patch(after_66)
    data = _data_of(env)
    # No stale diagnostic env, no stale diagnostic PHANTOM_CMD.
    assert data == {"POSITRONIC_MODE": "production"}
    assert not any(k.startswith("POSITRONIC_DIAGNOSTIC_") for k in data)
    assert "PHANTOM_CMD" not in data

    after_12 = _cmd_patch(PROD_CMD, field_absent=False, current=after_66)
    assert _data_of(_find_cmd_only_patch(after_12)) == {"PHANTOM_CMD": PROD_CMD}
    # And the merged env still has no diagnostic leftovers anywhere.
    blob = json.dumps(after_12)
    assert "POSITRONIC_DIAGNOSTIC_" not in blob
    assert LAUNCHER not in blob


# ── acceptance #3b: flip production -> diagnostic ────────────────────────────


def test_flip_production_to_diagnostic():
    # Cluster currently has production env + production PHANTOM_CMD patch.
    prod = _env_patch(PROD_KV, "production", [])
    prod = _cmd_patch(PROD_CMD, field_absent=False, current=prod)
    assert _find_cmd_only_patch(prod) is not None

    # Flip to diagnostic: 6.6 rewrites env (now owns launcher PHANTOM_CMD),
    # 12 scrubs the production PHANTOM_CMD-only patch.
    after_66 = _env_patch(DIAG_KV, "diagnostic", prod)
    after_12 = _cmd_patch("", field_absent=True, current=after_66)
    # Production PHANTOM_CMD patch gone; env patch owns the launcher.
    assert _find_cmd_only_patch(after_12) is None
    assert _data_of(_find_env_patch(after_12))["PHANTOM_CMD"] == LAUNCHER
    assert PROD_CMD not in json.dumps(after_12)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
