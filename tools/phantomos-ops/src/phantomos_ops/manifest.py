"""Manifest data model + loader.

M1 ships in-code sample data so the screen layout is verifiable
end-to-end before M2 wires the YAML loader. The dataclasses are the
shape M2 will populate from `manifest.yaml`, so screens written
against this module won't churn when the loader lands.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from .safety import SafetyClass


@dataclass(frozen=True)
class Group:
    id: str
    title: str
    order: int = 0


@dataclass(frozen=True)
class Action:
    id: str
    group: str                         # references Group.id
    title: str
    blurb: str
    safety: SafetyClass
    command: tuple[str, ...]           # argv list, never a shell string
    requires: tuple[str, ...] = ()
    runs_on: tuple[str, ...] = ("robot", "dev")
    duration: str = ""
    reversible: bool = True
    confirm_word: str = ""
    dry_run: tuple[str, ...] | None = None
    form: str | None = None


@dataclass(frozen=True)
class Manifest:
    groups: tuple[Group, ...]
    actions: tuple[Action, ...]

    def actions_in(self, group_id: str) -> tuple[Action, ...]:
        """Actions filed under a group, preserving manifest order."""
        return tuple(a for a in self.actions if a.group == group_id)

    def by_id(self, action_id: str) -> Action | None:
        for a in self.actions:
            if a.id == action_id:
                return a
        return None


# ---------------------------------------------------------------------
# Sample manifest used by M1. Mirrors the action vocabulary in
# docs/ops-tui-user-guide.md so the layout is verifiable end-to-end
# before the YAML loader lands in M2.

SAMPLE_MANIFEST = Manifest(
    groups=(
        Group("bootstrap",   "Bootstrap & Host",      order=1),
        Group("workloads",   "Workloads",             order=2),
        Group("streams",     "Recording & Streams",   order=3),
        Group("registry",    "Registry",              order=4),
        Group("builds",      "Builds",                order=5),
        Group("diagnostics", "Diagnostics",           order=6),
    ),
    actions=(
        Action(
            id="bootstrap.configure_host",
            group="bootstrap",
            title="Edit per-host configuration",
            blurb="Walks the operator through /etc/phantomos/host-config.yaml.",
            safety="yellow",
            requires=("root",),
            duration="interactive",
            command=("bash", "scripts/configure-host.sh"),
        ),
        Action(
            id="positronic.status",
            group="workloads",
            title="Show what positronic-control is doing right now",
            blurb=(
                "Snapshot of pod state: QoS, restarts, runtimeClass, "
                "PHANTOM_CMD (CM + as-seen by pod), PID 1 cmd."
            ),
            safety="green",
            requires=("kubectl",),
            duration="~1s",
            command=("bash", "scripts/positronic.sh", "status"),
        ),
        Action(
            id="positronic.logs",
            group="workloads",
            title="Tail positronic-control logs",
            blurb="Streams the main container's logs. Ctrl-C to stop.",
            safety="green",
            requires=("kubectl",),
            duration="streams",
            command=("bash", "scripts/positronic.sh", "logs", "-f"),
        ),
        Action(
            id="positronic.exec",
            group="workloads",
            title="Drop into a shell on positronic-control",
            blurb="Interactive bash inside the running pod.",
            safety="green",
            requires=("kubectl",),
            duration="interactive",
            command=("bash", "scripts/positronic.sh", "exec", "positronic"),
        ),
        Action(
            id="locomotion.exec",
            group="workloads",
            title="Drop into a shell on phantom-locomotion",
            blurb="Interactive bash inside the locomotion DaemonSet pod.",
            safety="green",
            requires=("kubectl",),
            duration="interactive",
            command=("bash", "scripts/positronic.sh", "exec", "locomotion"),
        ),
        Action(
            id="positronic.diagnose",
            group="workloads",
            title="Diagnose unhealthy positronic-control",
            blurb="Investigates pod health and optionally applies a fix.",
            safety="yellow",
            requires=("kubectl",),
            duration="~30s",
            command=("bash", "scripts/diagnose-positronic.sh"),
        ),
        Action(
            id="deployment.reset",
            group="workloads",
            title="Tear down + rebuild stateful resources",
            blurb=(
                "Deletes the core Argo Application + workloads in "
                "phantom, positronic, nimbus, argus. PVCs recreated; "
                "on-disk data preserved. ArgoCD reconciles from git."
            ),
            safety="red",
            requires=("kubectl",),
            duration="3-8 min",
            reversible=False,
            confirm_word="reset",
            command=("bash", "scripts/reset-deployment.sh"),
        ),
        Action(
            id="streams.record_start",
            group="streams",
            title="Start a recording",
            blurb="Sends RECORDING_START to the dma-recorder pod.",
            safety="yellow",
            requires=("kubectl",),
            duration="<1s",
            command=("bash", "scripts/dma-cmd.sh", "record", "start"),
        ),
        Action(
            id="streams.record_stop",
            group="streams",
            title="Stop the active recording",
            blurb="Sends RECORDING_STOP. Recorder flushes the current .rrd.",
            safety="yellow",
            requires=("kubectl",),
            duration="<1s",
            command=("bash", "scripts/dma-cmd.sh", "record", "stop"),
        ),
        Action(
            id="streams.ping",
            group="streams",
            title="Ping the recorder",
            blurb="Liveness probe. Prints round-trip latency.",
            safety="green",
            requires=("kubectl",),
            duration="<1s",
            command=("bash", "scripts/dma-cmd.sh", "ping"),
        ),
        Action(
            id="registry.validate",
            group="registry",
            title="Verify the local registry is wired up correctly",
            blurb="Runs the 13-test smoke suite against localhost:5443.",
            safety="green",
            requires=("kubectl",),
            duration="~30s",
            command=("bash", "scripts/validate-local-registry.sh"),
        ),
        Action(
            id="diagnostics.perfmon",
            group="diagnostics",
            title="Record system performance",
            blurb="CPU / GPU / EMC / power / perf counters → CSV + PNG.",
            safety="green",
            duration="streams",
            command=("python3", "scripts/thor-perfmon.py"),
        ),
    ),
)
