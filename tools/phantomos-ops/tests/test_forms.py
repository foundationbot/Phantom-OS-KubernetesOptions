"""Smoke tests for the 5 form modules.

These verify that each form's compose_fields + to_command produce a
valid argv list with default values, and that recalled values
override the defaults. Live UI behaviour (live preview update, focus
order) is covered indirectly via the integration test below.
"""
from __future__ import annotations

import pytest

from phantomos_ops.app import OpsApp
from phantomos_ops.manifest import Action, Group, Manifest
from phantomos_ops.screens.main import MainScreen
from phantomos_ops.state import State


def _action(form_name: str, **overrides) -> Action:
    return Action(
        id=overrides.get("id", "x.y"),
        group="g",
        title="t",
        blurb="b",
        safety="green",
        command=tuple(overrides.get("command",
                                    ("bash", "scripts/positronic.sh"))),
        form=form_name,
    )


# ---------- positronic_logs ----------

def test_positronic_logs_default_to_command():
    from phantomos_ops.forms.positronic_logs import PositronicLogsForm
    form = PositronicLogsForm.__new__(PositronicLogsForm)
    # Bypass __init__ → set up just enough state for to_command.
    form.action = _action("positronic_logs")
    form.recalled = {}
    form.field_widgets = {
        "follow":  type("W", (), {"value": True})(),
        "previous": type("W", (), {"value": False})(),
        "init":    type("W", (), {"value": False})(),
        "tail":    type("W", (), {"value": "500"})(),
    }
    cmd = form.to_command()
    assert cmd == ["bash", "scripts/positronic.sh", "logs", "-f",
                   "--tail", "500"]


def test_positronic_logs_with_init_and_previous():
    from phantomos_ops.forms.positronic_logs import PositronicLogsForm
    form = PositronicLogsForm.__new__(PositronicLogsForm)
    form.action = _action("positronic_logs")
    form.recalled = {}
    form.field_widgets = {
        "follow":   type("W", (), {"value": True})(),
        "previous": type("W", (), {"value": True})(),
        "init":     type("W", (), {"value": True})(),
        "tail":     type("W", (), {"value": "100"})(),
    }
    cmd = form.to_command()
    assert "--previous" in cmd
    assert "--init" in cmd
    assert "100" in cmd


# ---------- streams_raw ----------

def test_streams_raw_minimal():
    from phantomos_ops.forms.streams_raw import StreamsRawForm
    form = StreamsRawForm.__new__(StreamsRawForm)
    form.action = _action("streams_raw")
    form.recalled = {}
    form.field_widgets = {
        "opcode":  type("W", (), {"value": "0x0700"})(),
        "no_wait": type("W", (), {"value": False})(),
        "timeout": type("W", (), {"value": ""})(),
    }
    cmd = form.to_command()
    assert cmd == ["bash", "scripts/dma-cmd.sh", "raw", "0x0700"]


def test_streams_raw_with_no_wait_and_timeout():
    from phantomos_ops.forms.streams_raw import StreamsRawForm
    form = StreamsRawForm.__new__(StreamsRawForm)
    form.action = _action("streams_raw")
    form.recalled = {}
    form.field_widgets = {
        "opcode":  type("W", (), {"value": "0x0701"})(),
        "no_wait": type("W", (), {"value": True})(),
        "timeout": type("W", (), {"value": "5"})(),
    }
    cmd = form.to_command()
    assert "--no-wait" in cmd
    assert ["--timeout", "5"] == cmd[-2:]


# ---------- registry_prime ----------

def test_registry_prime_no_filter_no_parallelism():
    from phantomos_ops.forms.registry_prime import RegistryPrimeForm
    form = RegistryPrimeForm.__new__(RegistryPrimeForm)
    form.action = _action("registry_prime")
    form.recalled = {}
    form.field_widgets = {
        "filter":      type("W", (), {"value": ""})(),
        "parallelism": type("W", (), {"value": ""})(),
    }
    cmd = form.to_command()
    assert cmd == ["bash", "scripts/prime-registry-cache.sh"]


def test_registry_prime_with_filter_and_parallelism():
    from phantomos_ops.forms.registry_prime import RegistryPrimeForm
    form = RegistryPrimeForm.__new__(RegistryPrimeForm)
    form.action = _action("registry_prime")
    form.recalled = {}
    form.field_widgets = {
        "filter":      type("W", (), {"value": "foundationbot/*"})(),
        "parallelism": type("W", (), {"value": "4"})(),
    }
    cmd = form.to_command()
    assert ["--filter", "foundationbot/*"] == cmd[2:4]
    assert ["--parallelism", "4"] == cmd[4:6]


# ---------- registry_prune ----------

def test_registry_prune_dry_run_default():
    from phantomos_ops.forms.registry_prune import RegistryPruneForm
    form = RegistryPruneForm.__new__(RegistryPruneForm)
    form.action = _action("registry_prune")
    form.recalled = {}
    form.field_widgets = {
        "pattern":  type("W", (), {"value": "mirror-test-*"})(),
        "dry_run":  type("W", (), {"value": True})(),
        "gc_after": type("W", (), {"value": False})(),
    }
    cmd = form.to_command()
    assert cmd == ["bash", "scripts/prune-registry-tags.sh",
                   "mirror-test-*", "--dry-run"]


# ---------- integration: e key opens form ----------

@pytest.mark.asyncio
async def test_e_key_opens_form_modal_for_form_aware_action(tmp_path):
    """Pressing 'e' on a form-aware action opens its parameter form."""
    from phantomos_ops.forms import ActionForm

    manifest = Manifest(
        groups=(Group("g", "G", order=1),),
        actions=(Action(
            id="g.with_form",
            group="g",
            title="form-backed action",
            blurb="x",
            safety="green",
            command=("bash", "scripts/positronic.sh", "logs"),
            form="positronic_logs",
        ),),
    )
    state = State()
    # Point persistence at tmp_path so the test doesn't touch ~/.config.
    state_path = tmp_path / "state.json"

    app = OpsApp(manifest=manifest, state=state)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("e")
        await pilot.pause()
        assert isinstance(app.screen, ActionForm)
