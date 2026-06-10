"""Tests for the post-rebase improvements:

- per-phase bootstrap actions (single-phase re-runs)
- new-workload status/logs actions wired to scripts/workload.sh
- the bring_online --no-tailscale / --keep-going form
- workload.sh ships and is executable

These guard the manifest+form additions the same way test_forms.py and
test_production_manifest.py guard the originals.
"""
from __future__ import annotations

import os
import stat
from pathlib import Path

from phantomos_ops import manifest as m
from phantomos_ops.forms import get_form_class
from phantomos_ops.manifest import Action

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
PROD = ROOT / "src" / "phantomos_ops" / "manifest.yaml"


def _by_id(actions):
    return {a.id: a for a in actions}


# ---------- A: per-phase bootstrap actions ----------

def test_per_phase_bootstrap_actions_present_and_well_formed():
    mani, errors = m.load_manifest(PROD)
    assert errors == []
    by = _by_id(mani.actions)
    expected = {
        "bootstrap.gitops": "--gitops",
        "bootstrap.image_overrides": "--image-overrides",
        "bootstrap.deployments": "--deployments",
        "bootstrap.operator_ui_config": "--operator-ui-config",
        "bootstrap.locomotion_config": "--locomotion-config",
        "bootstrap.log_management": "--log-management",
    }
    for aid, flag in expected.items():
        assert aid in by, f"missing per-phase action {aid}"
        a = by[aid]
        assert a.group == "bootstrap"
        assert a.command == ("bash", "scripts/bootstrap-robot.sh", flag)
        # every single-phase action ships a --dry-run preview override
        assert a.dry_run == ("bash", "scripts/bootstrap-robot.sh", flag, "--dry-run")
        # idempotent re-runs are yellow, not red (no confirm wall)
        assert a.safety == "yellow"


# ---------- B: new-workload status/logs actions ----------

def test_new_workload_actions_use_workload_script():
    mani, _ = m.load_manifest(PROD)
    by = _by_id(mani.actions)
    expected = {
        "locomotion.status": ("status", "positronic", "phantom-locomotion"),
        "locomotion.logs": ("logs", "positronic", "phantom-locomotion"),
        "ik_mk2.status": ("status", "positronic", "ik-mk2"),
        "ik_mk2.logs": ("logs", "positronic", "ik-mk2"),
        "state_estimator.status": ("status", "positronic", "cpp-robot-state-estimator"),
        "state_estimator.logs": ("logs", "positronic", "cpp-robot-state-estimator"),
        "dma_bridge.status": ("status", "phantom", "dma-bridge"),
        "dma_bridge.logs": ("logs", "phantom", "dma-bridge"),
    }
    for aid, (action, ns, name) in expected.items():
        assert aid in by, f"missing workload action {aid}"
        a = by[aid]
        assert a.group == "workloads"
        assert a.safety == "green"          # read-only
        assert a.command[:5] == ("bash", "scripts/workload.sh", action, ns, name)
        if action == "logs":
            assert "-f" in a.command


def test_workload_script_exists_and_is_executable():
    script = REPO_ROOT / "scripts" / "workload.sh"
    assert script.is_file(), "scripts/workload.sh missing"
    mode = script.stat().st_mode
    assert mode & stat.S_IXUSR, "scripts/workload.sh not executable"


# ---------- C: bring_online form ----------

def _form_instance(cls, **values):
    """Build a form without a running Textual app (mirrors test_forms.py)."""
    form = cls.__new__(cls)
    form.recalled = {}
    form.field_widgets = {
        k: type("W", (), {"value": v})() for k, v in values.items()
    }
    return form


def test_bring_online_form_registered():
    assert get_form_class("bootstrap_bring_online") is not None


def test_bring_online_form_default_is_bare_bootstrap():
    from phantomos_ops.forms.bootstrap_bring_online import BootstrapBringOnlineForm
    form = _form_instance(BootstrapBringOnlineForm, no_tailscale=False, keep_going=False)
    assert form.to_command() == ["bash", "scripts/bootstrap-robot.sh"]


def test_bring_online_form_flags():
    from phantomos_ops.forms.bootstrap_bring_online import BootstrapBringOnlineForm
    form = _form_instance(BootstrapBringOnlineForm, no_tailscale=True, keep_going=True)
    cmd = form.to_command()
    assert cmd[:2] == ["bash", "scripts/bootstrap-robot.sh"]
    assert "--no-tailscale" in cmd
    assert "--keep-going" in cmd


def test_bring_online_action_references_the_form():
    mani, _ = m.load_manifest(PROD)
    a = _by_id(mani.actions)["bootstrap.bring_online"]
    assert a.form == "bootstrap_bring_online"
    # still a guarded red action
    assert a.safety == "red" and a.confirm_word
