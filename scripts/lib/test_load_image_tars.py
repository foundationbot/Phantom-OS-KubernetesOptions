"""Tests for scripts/load-image-tars.sh.

load-image-tars.sh is the scripted form of operations.md §3.13 step 3: it
`docker load`s image tarballs and `docker push`es their localhost:5443/* tags
into the in-cluster registry. It is a pure registry op (no host-config).

These tests exercise --dry-run ONLY, so they need neither docker nor a live
registry: in --dry-run the script validates file existence and prints the
docker load / push it WOULD run, without invoking docker/zstd/curl.

Covers:
  - --help exits 0 and prints usage.
  - a non-existent tarball path in --dry-run is reported as an error / nonzero.
  - .tar and .tar.zst paths are accepted and dry-run prints the appropriate
    would-run command (gzip-native load vs zstd pipe).
  - no args -> nonzero exit + usage.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "load-image-tars.sh"

BASH = shutil.which("bash")
if BASH is None:
    pytest.skip("bash not available", allow_module_level=True)


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def test_script_exists():
    assert SCRIPT.is_file(), f"missing script at {SCRIPT}"


def test_help_exits_zero_and_prints_usage():
    res = _run("--help")
    assert res.returncode == 0
    combined = res.stdout + res.stderr
    assert "load-image-tars.sh" in combined
    assert "--dry-run" in combined


def test_no_args_is_nonzero_with_usage():
    res = _run()
    assert res.returncode != 0
    combined = res.stdout + res.stderr
    assert "load-image-tars.sh" in combined  # usage was printed


def test_missing_tarball_in_dry_run_is_failure(tmp_path: Path):
    missing = tmp_path / "nope.tar"
    res = _run("--dry-run", str(missing))
    assert res.returncode != 0  # exit code == number of failures
    assert "not a readable file" in res.stderr


def test_dry_run_tar_prints_docker_load(tmp_path: Path):
    f = tmp_path / "phantom-models.tar"
    f.write_text("irrelevant in dry-run")
    res = _run("--dry-run", str(f))
    assert res.returncode == 0
    assert "would run: docker load -i" in res.stderr
    assert str(f) in res.stderr
    # No real push attempted; nothing parseable on stdout in dry-run.
    assert "PUSHED " not in res.stdout


def test_dry_run_zst_prints_zstd_pipe(tmp_path: Path):
    f = tmp_path / "phantom-policies.tar.zst"
    f.write_text("irrelevant in dry-run")
    res = _run("--dry-run", str(f))
    assert res.returncode == 0
    assert "zstd -dc" in res.stderr
    assert "docker load" in res.stderr
    assert str(f) in res.stderr


def test_dry_run_multiple_inputs_mixed_extensions(tmp_path: Path):
    tar = tmp_path / "a.tar"
    zst = tmp_path / "b.tar.zst"
    tar.write_text("x")
    zst.write_text("y")
    res = _run("--dry-run", str(tar), str(zst))
    assert res.returncode == 0
    assert "would run: docker load -i" in res.stderr
    assert "zstd -dc" in res.stderr
