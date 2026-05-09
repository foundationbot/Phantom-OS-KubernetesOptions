"""Manifest data model + loader.

The manifest is the single source of truth for the action registry.
M2 added the YAML loader; the SAMPLE_MANIFEST below stays in-tree
as a fallback used when the YAML file is missing — useful in tests
and when the package is imported from a context that doesn't ship
the asset.

Loader contract:
    manifest, errors = load_manifest(path)

Validation philosophy: bad individual entries are DROPPED with a
human-readable error string; the loader only RAISES (ManifestError)
on catastrophic issues — file missing, invalid YAML, top-level shape
wrong. This lets the app boot even with a partly-broken manifest
and surface the issue in a startup banner instead of a stack trace.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

import yaml

from .safety import SafetyClass

VALID_SAFETY: tuple[SafetyClass, ...] = ("green", "yellow", "red")
VALID_RUNS_ON: tuple[str, ...] = ("robot", "dev")


class ManifestError(Exception):
    """Raised for catastrophic load failures (missing file, invalid
    YAML, top-level shape wrong). Per-entry validation errors are
    returned as the second element of load_manifest's tuple instead."""


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


# ---------------------------------------------------------------------
# YAML loader

# Required action fields. A missing one drops the entry.
_REQUIRED_ACTION_FIELDS = ("id", "group", "title", "blurb", "safety", "command")
_REQUIRED_GROUP_FIELDS = ("id", "title")


def load_manifest(path: Path | str) -> tuple[Manifest, list[str]]:
    """Load + validate a manifest YAML file.

    Returns (manifest, errors). errors is empty when the file is fully
    valid; non-empty when individual entries were dropped.

    Raises ManifestError on catastrophic issues (file missing, invalid
    YAML, top-level shape wrong) — these aren't recoverable for the
    operator, so the caller should surface a hard banner.
    """
    p = Path(path)
    try:
        text = p.read_text()
    except (FileNotFoundError, PermissionError, IsADirectoryError) as exc:
        raise ManifestError(f"cannot read manifest at {p}: {exc}") from exc

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ManifestError(f"invalid YAML in {p}: {exc}") from exc

    if not isinstance(data, dict):
        raise ManifestError(f"{p}: top-level must be a mapping with "
                            "'groups' and 'actions' keys")

    errors: list[str] = []
    groups = _parse_groups(data.get("groups") or [], errors)
    actions = _parse_actions(data.get("actions") or [], groups, errors)

    return Manifest(groups=tuple(groups), actions=tuple(actions)), errors


def _parse_groups(raw: list[Any], errors: list[str]) -> list[Group]:
    out: list[Group] = []
    seen_ids: set[str] = set()
    for i, entry in enumerate(raw):
        loc = f"groups[{i}]"
        if not isinstance(entry, dict):
            errors.append(f"{loc}: must be a mapping")
            continue
        missing = [f for f in _REQUIRED_GROUP_FIELDS if f not in entry]
        if missing:
            errors.append(f"{loc}: missing required fields: {', '.join(missing)}")
            continue
        gid = entry["id"]
        if gid in seen_ids:
            errors.append(f"{loc}: duplicate group id {gid!r} — keeping first")
            continue
        seen_ids.add(gid)
        out.append(Group(
            id=gid,
            title=str(entry["title"]),
            order=int(entry.get("order", 0)),
        ))
    return out


def _parse_actions(
    raw: list[Any],
    groups: list[Group],
    errors: list[str],
) -> list[Action]:
    known_groups = {g.id for g in groups}
    out: list[Action] = []
    seen_ids: set[str] = set()

    for i, entry in enumerate(raw):
        loc = f"actions[{i}]"
        if not isinstance(entry, dict):
            errors.append(f"{loc}: must be a mapping")
            continue

        missing = [f for f in _REQUIRED_ACTION_FIELDS if f not in entry]
        if missing:
            errors.append(f"{loc}: missing required fields: {', '.join(missing)}")
            continue

        aid = str(entry["id"])
        if aid in seen_ids:
            errors.append(
                f"{loc}: duplicate action id {aid!r} — keeping first occurrence"
            )
            continue

        # Group reference must resolve.
        gref = entry["group"]
        if gref not in known_groups:
            errors.append(
                f"{loc} ({aid}): references unknown group {gref!r}"
            )
            continue

        # Safety must be one of the known classes.
        safety = entry["safety"]
        if safety not in VALID_SAFETY:
            errors.append(
                f"{loc} ({aid}): invalid safety {safety!r} — "
                f"must be one of {', '.join(VALID_SAFETY)}"
            )
            continue

        # Command must be argv list, never a shell string. A scalar
        # string would silently work via subprocess shell=False but
        # opens a shell-injection door once forms feed user values in.
        cmd = entry["command"]
        if not isinstance(cmd, list) or not all(isinstance(x, str) for x in cmd):
            errors.append(
                f"{loc} ({aid}): command must be a list of strings, "
                f"not {type(cmd).__name__}"
            )
            continue
        if len(cmd) == 0:
            errors.append(f"{loc} ({aid}): command must be non-empty")
            continue

        # Red actions need a confirm_word; otherwise the modal can't
        # render a magic-word prompt.
        confirm_word = str(entry.get("confirm_word") or "")
        if safety == "red" and not confirm_word:
            errors.append(
                f"{loc} ({aid}): safety=red requires a non-empty confirm_word"
            )
            continue

        # Optional list-shaped fields.
        requires = _parse_str_list(entry.get("requires"), loc, "requires", errors)
        if requires is None:
            continue
        runs_on = _parse_str_list(entry.get("runs_on"), loc, "runs_on", errors,
                                  default=("robot", "dev"))
        if runs_on is None:
            continue
        # runs_on tokens must be valid.
        bad = [t for t in runs_on if t not in VALID_RUNS_ON]
        if bad:
            errors.append(
                f"{loc} ({aid}): runs_on has unknown tokens {bad!r} — "
                f"valid: {', '.join(VALID_RUNS_ON)}"
            )
            continue

        dry_run_raw = entry.get("dry_run")
        if dry_run_raw is None:
            dry_run = None
        else:
            if not isinstance(dry_run_raw, list) \
                    or not all(isinstance(x, str) for x in dry_run_raw):
                errors.append(f"{loc} ({aid}): dry_run must be a list of strings")
                continue
            dry_run = tuple(dry_run_raw)

        seen_ids.add(aid)
        out.append(Action(
            id=aid,
            group=gref,
            title=str(entry["title"]),
            blurb=str(entry["blurb"]),
            safety=safety,                    # type: ignore[arg-type]
            command=tuple(cmd),
            requires=tuple(requires),
            runs_on=tuple(runs_on),
            duration=str(entry.get("duration") or ""),
            reversible=bool(entry.get("reversible", True)),
            confirm_word=confirm_word,
            dry_run=dry_run,
            form=(str(entry["form"]) if entry.get("form") else None),
        ))
    return out


def _parse_str_list(
    raw: Any,
    loc: str,
    field_name: str,
    errors: list[str],
    default: tuple[str, ...] = (),
) -> tuple[str, ...] | None:
    """Coerce raw → tuple[str,...] or record an error and return None.

    None signals "skip this entry" to the caller; an empty tuple is a
    valid result for a missing optional field.
    """
    if raw is None:
        return tuple(default)
    if not isinstance(raw, list) or not all(isinstance(x, str) for x in raw):
        errors.append(f"{loc}: {field_name} must be a list of strings")
        return None
    return tuple(raw)
