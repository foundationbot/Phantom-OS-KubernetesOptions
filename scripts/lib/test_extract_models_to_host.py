"""Tests for scripts/extract-models-to-host.sh.

extract-models-to-host.sh copies the model/policy trees baked into the
phantom-models / phantom-policies carrier images out onto the host so the
phantomos-api-server's hostPath mount (/root/models) is populated on a fresh
robot. It uses `docker create` + `docker cp` and is non-destructive (merges
into an existing /root/models; never wipes it).

Two test layers:
  - --dry-run / arg-parsing tests need neither docker nor root: the script
    validates args and prints the docker create/cp it WOULD run.
  - merge-behavior tests inject a *fake* docker via the DOCKER env var so the
    real copy/merge orchestration runs against a fixture image tree in tmp,
    with no real docker daemon or container.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "extract-models-to-host.sh"

BASH = shutil.which("bash")
if BASH is None:
    pytest.skip("bash not available", allow_module_level=True)


def _run(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    return subprocess.run(
        [BASH, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=full_env,
    )


# A fake `docker` that emulates `create`/`cp`/`rm`. `cp` understands docker's
# trailing-`/.` "copy contents into dest" semantics and copies from a fixture
# image tree rooted at $FAKE_IMAGE_ROOT.
FAKE_DOCKER = r"""#!/usr/bin/env bash
set -eu
cmd="$1"; shift
case "$cmd" in
  create) echo "fakecid_$$" ;;
  cp)
    spec="$1"; dest="$2"
    src="$FAKE_IMAGE_ROOT/${spec#*:}"   # strip "cid:" -> e.g. /models/.
    src="${src%/.}"                     # drop trailing /.  -> .../models
    mkdir -p "$dest"
    cp -a "$src/." "$dest/"
    ;;
  rm) : ;;
  *) echo "fake docker: unhandled $cmd" >&2; exit 99 ;;
esac
"""


def _make_fake_docker(tmp_path: Path) -> Path:
    d = tmp_path / "fakebin"
    d.mkdir()
    p = d / "docker"
    p.write_text(FAKE_DOCKER)
    p.chmod(0o755)
    return p


def _make_fixture_image(tmp_path: Path) -> Path:
    """An image rootfs with /models/<policy dirs> and /models/policies/*."""
    root = tmp_path / "imageroot"
    (root / "models" / "walking-imu-x").mkdir(parents=True)
    (root / "models" / "walking-imu-x" / "policy.onnx").write_text("WEIGHTS\n")
    (root / "models" / "policies").mkdir(parents=True)
    (root / "models" / "policies" / "model_encoder.onnx").write_text("ENC\n")
    return root


# ---- arg-parsing / dry-run (no docker needed) ------------------------------


def test_script_exists():
    assert SCRIPT.is_file(), f"missing script at {SCRIPT}"


def test_help_exits_zero_and_prints_usage():
    res = _run("--help")
    assert res.returncode == 0
    combined = res.stdout + res.stderr
    assert "extract-models-to-host.sh" in combined


def test_no_refs_is_nonzero_with_usage():
    res = _run()
    assert res.returncode != 0
    assert "extract-models-to-host.sh" in (res.stdout + res.stderr)


def test_dry_run_models_prints_docker_create_and_cp(tmp_path: Path):
    res = _run("--dry-run", "--dest", str(tmp_path / "m"),
               "--models-ref", "localhost:5443/phantom-models:2026-06-08")
    assert res.returncode == 0
    out = res.stdout + res.stderr
    assert "docker create" in out
    assert "/models/." in out


def test_dry_run_policies_targets_dest_policies(tmp_path: Path):
    dest = tmp_path / "m"
    res = _run("--dry-run", "--dest", str(dest),
               "--policies-ref", "localhost:5443/phantom-policies:2026-06-09-sonic-onnx")
    assert res.returncode == 0
    out = res.stdout + res.stderr
    assert "/models/policies/." in out
    assert str(dest / "policies") in out


# ---- real merge behavior (fake docker) -------------------------------------


def test_models_extracted_to_dest(tmp_path: Path):
    fake = _make_fake_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    res = _run("--dest", str(dest),
               "--models-ref", "localhost:5443/phantom-models:2026-06-08",
               env={"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img)})
    assert res.returncode == 0, res.stderr
    assert (dest / "walking-imu-x" / "policy.onnx").read_text() == "WEIGHTS\n"


def test_policies_extracted_to_dest_policies(tmp_path: Path):
    fake = _make_fake_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    res = _run("--dest", str(dest),
               "--policies-ref", "localhost:5443/phantom-policies:2026-06-09-sonic-onnx",
               env={"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img)})
    assert res.returncode == 0, res.stderr
    assert (dest / "policies" / "model_encoder.onnx").read_text() == "ENC\n"


def test_merge_is_non_destructive(tmp_path: Path):
    """A hand-placed file already under /root/models survives extraction."""
    fake = _make_fake_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    (dest / "hand-placed-policy").mkdir(parents=True)
    (dest / "hand-placed-policy" / "keep.onnx").write_text("KEEP\n")

    res = _run("--dest", str(dest),
               "--models-ref", "localhost:5443/phantom-models:2026-06-08",
               env={"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img)})
    assert res.returncode == 0, res.stderr
    # both the pre-existing tree and the newly-copied tree are present
    assert (dest / "hand-placed-policy" / "keep.onnx").read_text() == "KEEP\n"
    assert (dest / "walking-imu-x" / "policy.onnx").read_text() == "WEIGHTS\n"


def test_both_refs_in_one_invocation(tmp_path: Path):
    fake = _make_fake_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    res = _run("--dest", str(dest),
               "--models-ref", "localhost:5443/phantom-models:2026-06-08",
               "--policies-ref", "localhost:5443/phantom-policies:2026-06-09-sonic-onnx",
               env={"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img)})
    assert res.returncode == 0, res.stderr
    assert (dest / "walking-imu-x" / "policy.onnx").is_file()
    assert (dest / "policies" / "model_encoder.onnx").is_file()


# ---- idempotency (marker-driven skip on re-run) ----------------------------


# A counting fake docker: appends a line to $DOCKER_CALL_LOG for every
# create/cp/rm so a test can assert how many docker invocations happened.
FAKE_DOCKER_COUNTING = r"""#!/usr/bin/env bash
set -eu
echo "$@" >> "$DOCKER_CALL_LOG"
cmd="$1"; shift
case "$cmd" in
  create) echo "fakecid_$$" ;;
  cp)
    spec="$1"; dest="$2"
    src="$FAKE_IMAGE_ROOT/${spec#*:}"
    src="${src%/.}"
    mkdir -p "$dest"
    cp -a "$src/." "$dest/"
    ;;
  rm) : ;;
  *) echo "fake docker: unhandled $cmd" >&2; exit 99 ;;
esac
"""


def _make_counting_docker(tmp_path: Path) -> Path:
    d = tmp_path / "fakebin-counting"
    d.mkdir()
    p = d / "docker"
    p.write_text(FAKE_DOCKER_COUNTING)
    p.chmod(0o755)
    return p


def _docker_call_count(log: Path) -> int:
    if not log.exists():
        return 0
    return sum(1 for line in log.read_text().splitlines() if line.strip())


def test_rerun_same_ref_skips_no_docker_calls(tmp_path: Path):
    """A second run with the same ref makes ZERO docker calls (marker hit)."""
    fake = _make_counting_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    log = tmp_path / "docker-calls.log"
    ref = "localhost:5443/phantom-models:2026-06-08"
    env = {"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img), "DOCKER_CALL_LOG": str(log)}

    res1 = _run("--dest", str(dest), "--models-ref", ref, env=env)
    assert res1.returncode == 0, res1.stderr
    assert (dest / ".extracted-ref").read_text().strip() == ref
    first_calls = _docker_call_count(log)
    assert first_calls > 0  # the initial extract really ran docker

    res2 = _run("--dest", str(dest), "--models-ref", ref, env=env)
    assert res2.returncode == 0, res2.stderr
    # No NEW docker calls on the no-op re-run.
    assert _docker_call_count(log) == first_calls
    assert "skipping" in (res2.stdout + res2.stderr)


def test_force_reextracts(tmp_path: Path):
    """--force bypasses the marker and re-runs docker even on an unchanged ref."""
    fake = _make_counting_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    log = tmp_path / "docker-calls.log"
    ref = "localhost:5443/phantom-models:2026-06-08"
    env = {"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img), "DOCKER_CALL_LOG": str(log)}

    res1 = _run("--dest", str(dest), "--models-ref", ref, env=env)
    assert res1.returncode == 0, res1.stderr
    first_calls = _docker_call_count(log)

    res2 = _run("--dest", str(dest), "--force", "--models-ref", ref, env=env)
    assert res2.returncode == 0, res2.stderr
    # --force re-extracted: more docker calls than the first run alone.
    assert _docker_call_count(log) > first_calls


def test_different_ref_reextracts(tmp_path: Path):
    """A changed ref re-extracts (overlay) and updates the marker."""
    fake = _make_counting_docker(tmp_path)
    img = _make_fixture_image(tmp_path)
    dest = tmp_path / "root-models"
    log = tmp_path / "docker-calls.log"
    env = {"DOCKER": str(fake), "FAKE_IMAGE_ROOT": str(img), "DOCKER_CALL_LOG": str(log)}

    ref_a = "localhost:5443/phantom-models:2026-06-08"
    ref_b = "localhost:5443/phantom-models:2026-06-09"

    res1 = _run("--dest", str(dest), "--models-ref", ref_a, env=env)
    assert res1.returncode == 0, res1.stderr
    first_calls = _docker_call_count(log)
    assert (dest / ".extracted-ref").read_text().strip() == ref_a

    res2 = _run("--dest", str(dest), "--models-ref", ref_b, env=env)
    assert res2.returncode == 0, res2.stderr
    # Different ref -> docker ran again; marker now records ref_b.
    assert _docker_call_count(log) > first_calls
    assert (dest / ".extracted-ref").read_text().strip() == ref_b


def test_missing_docker_binary_is_clear_error(tmp_path: Path):
    dest = tmp_path / "root-models"
    res = _run("--dest", str(dest),
               "--models-ref", "localhost:5443/phantom-models:2026-06-08",
               env={"DOCKER": str(tmp_path / "no-such-docker")})
    assert res.returncode != 0
    assert "docker" in (res.stdout + res.stderr).lower()
