"""Regression test for FIR-464: configure-host.sh must PRESERVE a seed's
top-level `dmaEthercat:` block when it regenerates host-config.yaml from a
`--from-template` seed.

The wizard rebuilds host-config.yaml from a fixed schema. Before this fix it
emitted only the keys it explicitly handled and silently dropped a seeded
`dmaEthercat:` block (configPath / configSet). On a real (non-interactive)
robot deploy that broke bootstrap phase 12 ("install dma-ethercat"), which
reads dmaEthercat.configPath/configSet from host-config.yaml to locate the
per-robot SOEM JSON, with: "no dma-ethercat config for robot '<robot>'".

Unlike the other tests in this directory (which unit-test host-config.py
functions), the dropped-block bug lived in the bash render block of
configure-host.sh, so this test drives the shell script end-to-end as a
subprocess and asserts the written output retains the block.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest
import yaml

HERE = Path(__file__).resolve().parent
SCRIPTS_DIR = HERE.parent
CONFIGURE_HOST = SCRIPTS_DIR / "configure-host.sh"
HOST_CONFIG = HERE / "host-config.py"


def _run_configure_host(seed: Path, out: Path) -> subprocess.CompletedProcess:
    """Drive configure-host.sh non-interactively from `seed`, writing `out`.

    stdin is a stream of "y" answers so the "Write to <out>?" confirm is
    accepted; the final "Run bootstrap-robot.sh now?" confirm is answered
    "n" (we never want the test to chain into bootstrap). Extra newlines
    are harmless — the wizard fills every other field from the seed.
    """
    return subprocess.run(
        ["bash", str(CONFIGURE_HOST),
         "--from-template", str(seed),
         "--output", str(out)],
        input="y\ny\ny\nn\n",
        text=True,
        capture_output=True,
        cwd=str(SCRIPTS_DIR.parent),
    )


@pytest.fixture()
def seed_with_dma(tmp_path: Path) -> Path:
    """A minimal but valid seed carrying a top-level dmaEthercat block."""
    seed = tmp_path / "host-config.yaml"
    seed.write_text(
        "robot: phantom-0009\n"
        "aiPcUrl: http://100.64.0.9:5000\n"
        "targetRevision: main\n"
        "production: false\n"
        "stacks:\n"
        "  core:\n"
        "  operator:\n"
        "    enabled: true\n"
        "dmaEthercat:\n"
        "  configPath: phantom-0009.json\n"
    )
    return seed


def test_configure_host_preserves_dma_ethercat_config_path(seed_with_dma, tmp_path):
    out = tmp_path / "out.yaml"
    _run_configure_host(seed_with_dma, out)

    assert out.is_file(), "configure-host.sh did not write the output file"
    cfg = yaml.safe_load(out.read_text()) or {}
    assert isinstance(cfg.get("dmaEthercat"), dict), (
        "regenerated host-config.yaml dropped the top-level dmaEthercat: "
        "block (FIR-464)"
    )
    assert cfg["dmaEthercat"].get("configPath") == "phantom-0009.json"

    # The block must also be readable via the exact getter bootstrap phase 12
    # uses, so the dma-ethercat installer can resolve the per-robot JSON.
    got = subprocess.run(
        [sys.executable, str(HOST_CONFIG), str(out),
         "get-dma-ethercat-config-path"],
        text=True, capture_output=True,
    )
    assert got.returncode == 0
    assert got.stdout.strip() == "phantom-0009.json"

    # And the regenerated file must still validate.
    val = subprocess.run(
        [sys.executable, str(HOST_CONFIG), str(out), "validate"],
        text=True, capture_output=True,
    )
    assert val.returncode == 0, f"validation failed:\n{val.stdout}\n{val.stderr}"


def test_configure_host_preserves_dma_ethercat_config_set(tmp_path):
    """configSet (robot-agnostic directory name) is carried just like
    configPath — bootstrap appends /<robot>.json at install time."""
    seed = tmp_path / "host-config.yaml"
    seed.write_text(
        "robot: phantom-0001\n"
        "aiPcUrl: http://100.64.0.1:5000\n"
        "stacks:\n"
        "  core:\n"
        "  operator:\n"
        "    enabled: true\n"
        "dmaEthercat:\n"
        "  configSet: test_single_novanta\n"
    )
    out = tmp_path / "out.yaml"
    _run_configure_host(seed, out)

    assert out.is_file()
    cfg = yaml.safe_load(out.read_text()) or {}
    assert cfg.get("dmaEthercat", {}).get("configSet") == "test_single_novanta"


def test_configure_host_omits_dma_ethercat_when_seed_has_none(tmp_path):
    """A seed without dmaEthercat must NOT gain an empty block — bootstrap's
    phase-12 picker still owns that fresh-robot case."""
    seed = tmp_path / "host-config.yaml"
    seed.write_text(
        "robot: phantom-0002\n"
        "aiPcUrl: http://100.64.0.2:5000\n"
        "stacks:\n"
        "  core:\n"
        "  operator:\n"
        "    enabled: true\n"
    )
    out = tmp_path / "out.yaml"
    _run_configure_host(seed, out)

    assert out.is_file()
    cfg = yaml.safe_load(out.read_text()) or {}
    assert "dmaEthercat" not in cfg
