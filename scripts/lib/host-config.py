#!/usr/bin/env python3
"""
host-config.py — read /etc/phantomos/host-config.yaml and emit pieces
of it for shell consumers.

The host-config file is the single per-host source-of-truth. Bootstrap
uses this helper to extract one field at a time so the bash script stays
free of YAML parsing logic.

Usage:
  host-config.py <path> get robot
  host-config.py <path> get aiPcUrl
  host-config.py <path> get-dma-ethercat-config-set
  host-config.py <path> get-dma-ethercat-config-path
  host-config.py <path> set-dma-ethercat-config-path <value>
  host-config.py <path> get-cpu-isolation-json
  host-config.py <path> set-cpu-isolation-json <json>
  host-config.py <path> get-log-management-json
  host-config.py <path> get-node-labels-json
  host-config.py <path> get-node-label-defaults       # TSV: key\tdefault\tdescription
  host-config.py <path> get-phantom-locomotion-policy
  host-config.py <path> get-phantom-locomotion-config-kv
  host-config.py <path> get-phantom-sonic-config-kv
  host-config.py <path> get-phantom-psi-config-kv
  host-config.py <path> get-images-json
  host-config.py <path> get-image-for-container <container>
  host-config.py <path> get-deployment-patches-json
  host-config.py <path> set-positronic-launch-command <value>
  host-config.py <path> clear-positronic-launch-command
  host-config.py <path> get-enabled-stacks            # one stack name per line
  host-config.py <path> get-stack-selfheal <stack>    # 'true' | 'false'
  host-config.py <path> get-git-source                # 'local' | 'remote' (default 'local')
  host-config.py <path> inject-kustomize-block <app-yaml> <stack> <stacks-dir>
  host-config.py <path> validate

Exit codes:
  0   success (value printed to stdout for `get`)
  1   field missing or empty (a missing optional field is the caller's
      problem — stdout will be empty and exit will be 1; bash should
      treat a 1 as "not set" rather than an error)
  2   file missing or YAML invalid
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml  # PyYAML — already present via apt python3-yaml
except ModuleNotFoundError:
    print(
        "error: PyYAML missing. Install with: apt-get install -y python3-yaml",
        file=sys.stderr,
    )
    sys.exit(2)


# Stack registry. Order is significant — bootstrap renders+applies in
# this order so `core` (registry, positronic, dma-video, ...) comes up
# before `operator` (which doesn't depend on core but reads better when
# core is already healthy).
KNOWN_STACKS: tuple[str, ...] = ("core", "operator")
# Stacks that cannot be disabled — robot is non-functional without them.
REQUIRED_STACKS: frozenset[str] = frozenset({"core"})


# logManagement defaults. Applied when the host-config block is absent
# or has missing children. Opt-out (set enabled: false), not opt-in,
# because the failure mode (793 GB /var/log/syslog filling the disk)
# is severe — a fresh robot should never ship without these caps.
LOG_MANAGEMENT_DEFAULTS: dict = {
    "enabled": True,
    "journald": {"systemMaxUse": "2G", "systemMaxFileSize": "100M"},
    "rsyslog": {
        "maxsize": "500M",
        "rotate": 7,
        "frequency": "daily",
        "compress": True,
    },
}
LOG_MANAGEMENT_VALID_FREQUENCIES: frozenset[str] = frozenset({"daily", "weekly"})


# Kubernetes label syntax. Key = optional DNS-1123-subdomain prefix
# + '/' + a name part; value = up to 63 chars of alnum + - _ .
# starting and ending with alnum (or empty). Names start with a
# letter to keep the prefix-vs-name distinction unambiguous.
_K8S_LABEL_KEY_RE = re.compile(
    r"^([A-Za-z0-9][-A-Za-z0-9_.]*[A-Za-z0-9]/)?"
    r"[A-Za-z][-A-Za-z0-9_.]*[A-Za-z0-9]$"
)
_K8S_LABEL_VALUE_RE = re.compile(
    r"^(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?$"
)
# foundation.bot/robot is bootstrap-managed (always 'true' on every
# robot). nodeLabels: in host-config.yaml cannot set or override it.
RESERVED_NODE_LABEL_KEYS: frozenset[str] = frozenset({"foundation.bot/robot"})

# Canonical registry of foundation.bot/has-* node labels that gate
# workloads in this repo. Single source of truth for:
#   1. configure-host.sh — emits the nodeLabels: block with all keys
#      present, defaults applied, and one comment per key explaining
#      what each gates.
#   2. bootstrap-robot.sh — _reconcile_node_labels uses these defaults
#      to fill in keys the operator omitted from host-config.yaml.
#   3. validators / future tooling.
#
# To add a new gate: append a tuple here AND add the matching
# nodeSelector to the gated manifest under manifests/base/. Keep
# alphabetical by key so the rendered file diffs cleanly when a new
# entry is inserted.
#
# Tuple: (key, default, description-shown-as-comment-in-host-config).
NODE_LABEL_REGISTRY: tuple[tuple[str, str, str], ...] = (
    ("foundation.bot/has-as-inference",
     "false",
     "as-inference DaemonSet (action-solver z_ref consumer; produces "
     "/as_action for the WBC — co-schedules with wm-inference, NOT in the "
     "has-positronic/locomotion/sonic exclusion group)"),
    ("foundation.bot/has-cameras",
     "true",
     "dma-video stack (mediamtx, camera-params, rtsp-streamer, producer, viewer)"),
    ("foundation.bot/has-dma-bridge",
     "true",
     "dma-bridge DaemonSet (FE WebSocket bridge :9098)"),
    ("foundation.bot/has-ik-mk2",
     "false",
     "ik-mk2 DaemonSet (MK2 upper-body IK shim, positronic ns)"),
    ("foundation.bot/has-locomotion",
     "false",
     "phantom-locomotion DaemonSet (mutually exclusive with has-positronic)"),
    ("foundation.bot/has-okvis",
     "false",
     "okvis2x DaemonSet (OKVIS2-X live dense-stereo SLAM, GPU + DMA shm)"),
    ("foundation.bot/has-positronic",
     "true",
     "positronic-control Deployment"),
    ("foundation.bot/has-psi",
     "false",
     "phantom-psi DaemonSet (Ψ₀ VLA + loco bridge; mutually exclusive with "
     "has-sonic, has-locomotion and has-positronic)"),
    ("foundation.bot/has-psi-dma-walking",
     "false",
     "psi0-dma-walking DaemonSet (Ψ₀ Early-fan whole-body policy over the DMA "
     "plane, spec 013; mutually exclusive with has-sonic, has-locomotion and "
     "has-positronic — it drives /desired)"),
    ("foundation.bot/has-recorder",
     "true",
     "dma-recorder DaemonSet (dma-streams)"),
    ("foundation.bot/has-sonic",
     "false",
     "phantom-sonic DaemonSet (Walking+SONIC; mutually exclusive with "
     "has-locomotion and has-positronic)"),
    ("foundation.bot/has-state-estimator",
     "false",
     "cpp-robot-state-estimator DaemonSet"),
    ("foundation.bot/has-streamer",
     "false",
     "rerun-streamer Deployment (dma-streams)"),
    ("foundation.bot/has-wm-inference",
     "false",
     "wm-inference DaemonSet (world-model z_ref service; feeds "
     "positronic-control — co-schedules with the control brain, NOT "
     "in the has-positronic/locomotion/sonic exclusion group)"),
    ("foundation.bot/has-wolverine-loco",
     "false",
     "wolverine-loco DaemonSet (MK2 whole-body velocity-locomotion, pure-C++ "
     "1 kHz node + teleop web-UI sidecar; mutually exclusive with "
     "has-positronic/locomotion/sonic — all drive /desired)"),
    ("foundation.bot/has-yovariable",
     "true",
     "yovariable-server DaemonSet"),
)


def _stack_spec(cfg: dict, name: str) -> dict:
    """Return the stacks.<name> mapping from cfg, or {} if absent.
    Always returns a dict (caller doesn't have to type-check)."""
    spec = (cfg.get("stacks") or {}).get(name)
    return spec if isinstance(spec, dict) else {}


def _stack_enabled(cfg: dict, name: str) -> bool:
    """A stack is enabled when it's required (core) OR its enabled
    field is missing (default true) OR its enabled field is true."""
    if name in REQUIRED_STACKS:
        return True
    spec = _stack_spec(cfg, name)
    if "enabled" not in spec:
        return True  # default
    return bool(spec["enabled"])


def _stack_selfheal(cfg: dict, name: str) -> bool:
    """Per-stack selfHeal override > top-level production: > false."""
    spec = _stack_spec(cfg, name)
    if "selfHeal" in spec:
        return bool(spec["selfHeal"])
    return bool(cfg.get("production"))


def load(path: str) -> dict:
    p = Path(path)
    if not p.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        sys.exit(2)
    try:
        with p.open("r") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        print(f"error: invalid YAML in {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    if data is None:
        return {}
    if not isinstance(data, dict):
        print(f"error: {path} top-level must be a mapping", file=sys.stderr)
        sys.exit(2)
    return data


def cmd_get(cfg: dict, field: str) -> int:
    value = cfg.get(field)
    if value is None or value == "":
        return 1
    print(value)
    return 0


def cmd_get_dma_ethercat_config_set(cfg: dict) -> int:
    """Print dmaEthercat.configSet (a single directory name under
    /usr/share/dma-ethercat/config/) or exit 1 if unset."""
    block = cfg.get("dmaEthercat") or {}
    if not isinstance(block, dict):
        return 1
    value = block.get("configSet")
    if not value:
        return 1
    print(value)
    return 0


def cmd_get_dma_ethercat_config_path(cfg: dict) -> int:
    """Print dmaEthercat.configPath (a path to a JSON file, absolute or
    relative to /usr/share/dma-ethercat/config/) or exit 1 if unset."""
    block = cfg.get("dmaEthercat") or {}
    if not isinstance(block, dict):
        return 1
    value = block.get("configPath")
    if not value:
        return 1
    print(value)
    return 0


def cmd_get_git_source(cfg: dict) -> int:
    """Print the gitSource field. Defaults to 'local' when absent.
    Always exits 0 — gitSource has a real default, unlike most other
    optional fields where 'unset' is meaningful to the caller.
    """
    value = cfg.get("gitSource") or "local"
    print(value)
    return 0


def cmd_set_dma_ethercat_config_path(path: str, value: str) -> int:
    """Persist dmaEthercat.configPath into the host-config file in
    place. Strips any existing top-level dmaEthercat: block (key plus
    its indented children) and appends a fresh block at EOF.

    Line-based rewrite — preserves comments and ordering elsewhere; the
    rewritten dmaEthercat block loses any comments it had (acceptable;
    the operator opted in by re-running the prompt)."""
    p = Path(path)
    if not p.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 2
    if not value or not isinstance(value, str):
        print("error: configPath value required", file=sys.stderr)
        return 2

    src = p.read_text().splitlines(keepends=True)
    out: list[str] = []
    skipping = False
    for line in src:
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if skipping:
            # End the skip when we hit another top-level key (indent 0,
            # non-blank, not a comment-only line).
            if (
                indent == 0
                and stripped.strip()
                and not stripped.startswith("#")
            ):
                skipping = False
                out.append(line)
            # else: still inside the dmaEthercat block — drop the line
            continue
        if indent == 0 and stripped.startswith("dmaEthercat:"):
            skipping = True
            continue
        out.append(line)

    if out and not out[-1].endswith("\n"):
        out[-1] = out[-1] + "\n"
    out.append("dmaEthercat:\n")
    out.append(f"  configPath: {value}\n")

    p.write_text("".join(out))
    return 0


def _json_string_literal(value: str) -> str:
    """Render `value` as a YAML-safe double-quoted string literal.
    JSON's escaping rules are a strict subset of YAML's double-quoted
    flow-scalar rules, so json.dumps() output is always valid YAML.
    Used by the launchCommand setter to round-trip arbitrary command
    strings (with colons, quotes, dollars) without bespoke escaping."""
    return json.dumps(value, ensure_ascii=False)


def cmd_set_positronic_launch_command(path: str, value: str) -> int:
    """Persist deployments.positronic-control.launchCommand into the
    host-config file in place. Used by positronic.sh set-cmd's durable
    mode (FIR-408): the operator's runtime override becomes the
    declarative source-of-truth so the next Argo sync doesn't revert it.

    Line-based rewrite. Cases handled:
      (a) launchCommand already exists under
          deployments.positronic-control -> replace value in place.
      (b) deployments.positronic-control exists but has no
          launchCommand -> insert as the first child of the block.
      (c) deployments: exists but no positronic-control entry ->
          append a positronic-control: child with launchCommand.
      (d) deployments: block absent entirely -> append a fresh
          deployments: block at EOF with positronic-control:
          launchCommand: <value>.

    Existing comments / ordering outside the touched lines are
    preserved. Pass an empty string to clear the value (writes
    'launchCommand: \"\"' rather than removing the key — see
    cmd_clear_positronic_launch_command for full removal)."""
    p = Path(path)
    if not p.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 2
    if not isinstance(value, str):
        print("error: launchCommand value must be a string", file=sys.stderr)
        return 2

    lit = _json_string_literal(value)
    src = p.read_text().splitlines(keepends=True)

    # Locate deployments:, positronic-control:, launchCommand: line spans.
    # Line indices are 0-based; we record the END of each block (last
    # line of indented children) so inserts go at the right position.
    deployments_line: "int | None" = None
    positronic_line: "int | None" = None
    launch_line: "int | None" = None
    positronic_block_end: "int | None" = None  # inclusive

    def _line_indent(line: str) -> int:
        return len(line) - len(line.lstrip(" "))

    def _is_yaml_key_line(line: str) -> bool:
        stripped = line.lstrip(" ")
        return bool(stripped.strip()) and not stripped.startswith("#")

    n = len(src)
    i = 0
    while i < n:
        line = src[i]
        if _line_indent(line) == 0 and line.lstrip(" ").startswith("deployments:"):
            deployments_line = i
            # Walk forward over the deployments block (indent > 0).
            j = i + 1
            while j < n:
                if _is_yaml_key_line(src[j]) and _line_indent(src[j]) == 0:
                    break
                stripped_j = src[j].lstrip(" ")
                if (
                    _line_indent(src[j]) == 2
                    and stripped_j.startswith("positronic-control:")
                ):
                    positronic_line = j
                    # Walk over positronic-control block (indent >= 4).
                    k = j + 1
                    while k < n:
                        if (
                            _is_yaml_key_line(src[k])
                            and _line_indent(src[k]) <= 2
                        ):
                            break
                        stripped_k = src[k].lstrip(" ")
                        if (
                            _line_indent(src[k]) == 4
                            and stripped_k.startswith("launchCommand:")
                        ):
                            launch_line = k
                        k += 1
                    positronic_block_end = k - 1
                j += 1
            break
        i += 1

    # Case (a): launchCommand already exists — replace in place.
    if launch_line is not None:
        src[launch_line] = f"    launchCommand: {lit}\n"
        p.write_text("".join(src))
        return 0

    # Case (b): positronic-control exists, no launchCommand — insert.
    if positronic_line is not None:
        insert_at = positronic_line + 1
        src.insert(insert_at, f"    launchCommand: {lit}\n")
        p.write_text("".join(src))
        return 0

    # Case (c): deployments: exists, no positronic-control — append entry.
    if deployments_line is not None:
        # Append after the last line of the deployments block. We can
        # compute that by finding the next zero-indent key line after
        # deployments_line (or EOF).
        j = deployments_line + 1
        while j < n:
            if _is_yaml_key_line(src[j]) and _line_indent(src[j]) == 0:
                break
            j += 1
        block = (
            "  positronic-control:\n"
            f"    launchCommand: {lit}\n"
        )
        src.insert(j, block)
        p.write_text("".join(src))
        return 0

    # Case (d): no deployments: block — append at EOF.
    if src and not src[-1].endswith("\n"):
        src[-1] = src[-1] + "\n"
    src.append("\n")
    src.append("# deployments.positronic-control.launchCommand persisted\n")
    src.append("# by positronic.sh set-cmd (FIR-408).\n")
    src.append("deployments:\n")
    src.append("  positronic-control:\n")
    src.append(f"    launchCommand: {lit}\n")
    p.write_text("".join(src))
    return 0


def cmd_clear_positronic_launch_command(path: str) -> int:
    """Remove deployments.positronic-control.launchCommand from the
    host-config file. Used by positronic.sh clear-cmd's durable mode.

    Removes ONLY the launchCommand line; the surrounding
    positronic-control block (mounts, etc.) is left intact. Returns 0
    whether or not the field was present (idempotent)."""
    p = Path(path)
    if not p.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    src = p.read_text().splitlines(keepends=True)

    def _line_indent(line: str) -> int:
        return len(line) - len(line.lstrip(" "))

    def _is_yaml_key_line(line: str) -> bool:
        stripped = line.lstrip(" ")
        return bool(stripped.strip()) and not stripped.startswith("#")

    n = len(src)
    out: list[str] = []
    in_deployments = False
    in_positronic = False
    for i, line in enumerate(src):
        if _line_indent(line) == 0 and line.lstrip(" ").startswith("deployments:"):
            in_deployments = True
            in_positronic = False
            out.append(line)
            continue
        if in_deployments:
            if _is_yaml_key_line(line) and _line_indent(line) == 0:
                in_deployments = False
                in_positronic = False
            elif (
                _line_indent(line) == 2
                and line.lstrip(" ").startswith("positronic-control:")
            ):
                in_positronic = True
                out.append(line)
                continue
            elif _is_yaml_key_line(line) and _line_indent(line) == 2:
                # New deployment entry — leave positronic-control scope.
                in_positronic = False
        if (
            in_positronic
            and _line_indent(line) == 4
            and line.lstrip(" ").startswith("launchCommand:")
        ):
            # Drop this line. Also drop the preceding comment line if it
            # exists and is the marker we wrote (keeps round-trips clean).
            if (
                out
                and out[-1].lstrip(" ").startswith("#")
                and "FIR-407" in out[-1]
            ):
                out.pop()
            continue
        out.append(line)

    p.write_text("".join(out))
    return 0


# Containers whose image MUST live in the in-cluster local registry
# (localhost:5443/*). These are locally-built busybox carrier images with
# no DockerHub upstream and no containerd mirror fallthrough — a non-local
# ref would never resolve on the robot. Used by cmd_set_image (Component B
# of the offline image-tarball provisioning design, 2026-06-22).
LOCAL_REGISTRY_PREFIX: str = "localhost:5443/"
LOCAL_REGISTRY_ONLY_CONTAINERS: frozenset[str] = frozenset(
    {"phantom-models", "phantom-policies"}
)


def cmd_set_image(path: str, container: str, ref: str) -> int:
    """Persist images.<container>.image: <ref> into the host-config file
    in place, preserving surrounding comments / formatting. Component B
    of the offline image-tarball provisioning design (2026-06-22) — the
    setter the --load-image-tars bootstrap phase calls after pushing a
    docker-save'd tarball into the local registry.

    Line-based rewrite, mirroring cmd_set_positronic_launch_command.
    Cases handled:
      (a) images.<container>.image already exists -> replace value.
      (b) images: block exists but has no <container> entry -> insert a
          '  <container>:\\n    image: <ref>\\n' entry under images:.
      (c) images: block absent entirely -> append a fresh images: block
          at EOF with the one entry.

    Validation:
      - <container> must be a key in CONTAINER_TARGETS.
      - <ref> must be a non-empty repo:tag string (per _split_image_ref).
      - phantom-models / phantom-policies are local-registry-only: a ref
        that does not start with 'localhost:5443/' is rejected."""
    p = Path(path)
    if not p.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    if container not in CONTAINER_TARGETS:
        print(
            f"error: unknown container {container!r} "
            f"(valid: {', '.join(sorted(CONTAINER_TARGETS))})",
            file=sys.stderr,
        )
        return 2

    if not isinstance(ref, str) or not ref.strip():
        print("error: image ref must be a non-empty string", file=sys.stderr)
        return 2
    ref = ref.strip()
    try:
        _split_image_ref(ref)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if (
        container in LOCAL_REGISTRY_ONLY_CONTAINERS
        and not ref.startswith(LOCAL_REGISTRY_PREFIX)
    ):
        print(
            f"error: container {container!r} is local-registry-only; "
            f"ref {ref!r} must start with {LOCAL_REGISTRY_PREFIX!r}",
            file=sys.stderr,
        )
        return 2

    src = p.read_text().splitlines(keepends=True)

    def _line_indent(line: str) -> int:
        return len(line) - len(line.lstrip(" "))

    def _is_yaml_key_line(line: str) -> bool:
        stripped = line.lstrip(" ")
        return bool(stripped.strip()) and not stripped.startswith("#")

    # Locate images:, <container>:, image: line spans. We record the END
    # of the images block so a new <container> entry inserts at the right
    # position.
    images_line: "int | None" = None
    container_line: "int | None" = None
    image_line: "int | None" = None
    images_block_end: "int | None" = None  # exclusive insert point

    n = len(src)
    i = 0
    while i < n:
        line = src[i]
        if _line_indent(line) == 0 and line.lstrip(" ").startswith("images:"):
            images_line = i
            # Walk forward over the images block (indent > 0 or blank/comment).
            j = i + 1
            while j < n:
                if _is_yaml_key_line(src[j]) and _line_indent(src[j]) == 0:
                    break
                stripped_j = src[j].lstrip(" ")
                if (
                    _line_indent(src[j]) == 2
                    and stripped_j.startswith(f"{container}:")
                ):
                    container_line = j
                    # Walk over the <container> block (indent >= 4).
                    k = j + 1
                    while k < n:
                        if _is_yaml_key_line(src[k]) and _line_indent(src[k]) <= 2:
                            break
                        stripped_k = src[k].lstrip(" ")
                        if (
                            _line_indent(src[k]) == 4
                            and stripped_k.startswith("image:")
                        ):
                            image_line = k
                        k += 1
                j += 1
            images_block_end = j
            break
        i += 1

    # Case (a): image: line already exists — replace the value in place.
    if image_line is not None:
        src[image_line] = f"    image: {ref}\n"
        p.write_text("".join(src))
        print(f"set images.{container}.image = {ref}")
        return 0

    # Case (a'): <container> exists but has no image: line — insert one.
    if container_line is not None:
        src.insert(container_line + 1, f"    image: {ref}\n")
        p.write_text("".join(src))
        print(f"set images.{container}.image = {ref}")
        return 0

    # Case (b): images: block exists, no <container> entry — append entry
    # at the end of the images block.
    if images_line is not None:
        assert images_block_end is not None
        block = f"  {container}:\n    image: {ref}\n"
        src.insert(images_block_end, block)
        p.write_text("".join(src))
        print(f"set images.{container}.image = {ref}")
        return 0

    # Case (c): no images: block — append a fresh one at EOF.
    if src and not src[-1].endswith("\n"):
        src[-1] = src[-1] + "\n"
    src.append("images:\n")
    src.append(f"  {container}:\n")
    src.append(f"    image: {ref}\n")
    p.write_text("".join(src))
    print(f"set images.{container}.image = {ref}")
    return 0


DEFAULT_LOCOMOTION_POLICY: str = "mk2-walking-lower-body-1imu"

# Locomotion modes. 'policy' (default) runs the normal dma_policy_node
# stack; 'diagnostic' flips dma_launch.sh to exec the wire-integrity
# diagnostic (inference.dma_diagnostic_node) introduced in
# foundationbot/phantom-locomotion#5 (FIR-337).
DEFAULT_LOCOMOTION_MODE: str = "policy"
ALLOWED_LOCOMOTION_MODES: frozenset[str] = frozenset({"policy", "diagnostic"})

# Defaults for the diagnostic subblock. Mirror the dma_launch.sh defaults
# and the node's own argparse defaults so a bare `mode: diagnostic` with
# no subblock works.
# Hold defaults are tuned for a real bench fixture: long enough that
# mechanical drive/linkage transients settle before the analyser's
# last-25% steady-state window. Override per-host if your fixture
# settles faster or slower.
DEFAULT_LOCOMOTION_DIAGNOSTIC: dict[str, str] = {
    "robot":        "mk2-lower-body",
    "naming":       "mj",
    "bias":         "0.10",
    "masterGain":   "0.3",
    "holdBiasS":    "2.0",
    "holdHomeS":    "1.0",
    "joints":       "all",
    # /recordings is a hostPath mount (foundationbot/Phantom-OS-
    # KubernetesOptions phantom-locomotion.yaml: host /root/recordings,
    # type DirectoryOrCreate). The launcher mkdir -p's the diag_reports
    # subdirectory before each batch. Stays under /recordings so reports
    # survive DaemonSet rollouts and sit next to dma-recorder's .rrd
    # files. Override to /dev/shm/diag_report.json on dev pods that lack
    # the /recordings mount.
    "outPath":      "/recordings/diag_reports/diag_report.json",
    # waitForStart gates dma_diagnostic_node on a joystick X-button
    # press (publishes /phantom/start_startup), same OFF->STARTUP
    # semantics as the policy node. Default "true" mirrors the
    # bench-operator workflow; set to "false" for headless / CI runs
    # where no joystick is attached. Stored as lowercase string so the
    # bash check `[ "$X" = "true" ]` in dma_launch.sh matches directly.
    "waitForStart": "true",
    # Per-joint bias overrides. Comma-separated NAME=VALUE list that
    # gets forwarded to the diagnostic node as one --joint-bias arg per
    # entry. Default empty (use the global --bias for every joint).
    # Example for mk2-lower-body where +RightHipRoll collides with the
    # left leg on the bench fixture:
    #   jointBiasOverrides: "RightHipRoll=-0.10"
    # FIR-339.
    "jointBiasOverrides": "",
    # Number of times to repeat the joint sweep back-to-back per run.
    # Each iteration writes its own timestamped report; the stable
    # `outPath` symlink always points at the latest. The joystick
    # `waitForStart` gate fires only on iteration 1, so the operator
    # presses X once and the remaining iterations run consecutively.
    "iterations": "1",
    # ── Ramp mode (FIR-342). `rampS=0.0` (default) keeps step mode
    # bit-for-bit identical to the pre-FIR-342 behaviour. When `rampS
    # > 0` the diagnostic ramps the bias position linearly over `rampS`
    # seconds, plateaus for `holdBiasS` (same field used in step mode),
    # then ramps back over `returnRampS` — exposing the analytic desired
    # velocity to the new vel-tracking verdict.
    # Default `returnRampS` ("") leaves the field unset so the
    # diagnostic node's argparse falls back to `rampS` for a symmetric
    # ramp; override only when you want asymmetric ramp down (e.g. a
    # gentler return on a heavy linkage).
    "rampS":               "0.0",
    "returnRampS":         "",
    # ±band around 1.0 for the vel_tracking_ratio PASS verdict. 0.30 →
    # [0.70, 1.30]. Host-config emits the expanded band as two env
    # vars consumed by dma_launch.sh (kept as a single op-facing knob).
    "velTrackingRatioTol": "0.30",
    "velTrackingLagMaxMs": "60.0",
    # ── IMU integrity tests (FIR-341). Defaults match the analyzer's
    # built-in thresholds; operators only override per-fixture if noise
    # floors or mechanical mounting differ from the design doc. Set
    # `skipImuTests: true` to disable Tests A-D entirely (joint-side
    # verdicts continue running).
    "skipImuTests":      "false",
    "gravityTol":        "0.05",
    # ±band around 1.0 for |proj_gravity| magnitude. 0.05 → [0.95, 1.05].
    "gravityMagTol":     "0.05",
    "gravityDriftTol":   "0.02",
    "imuProjGXyTol":     "0.10",
    "imuPelvisYawTol":   "0.30",
    "imuQuatDeltaTol":   "0.30",
    "imuGyroNoiseFloor": "0.10",
    "imuIdleGyroTol":    "0.30",
    "imuIdleProjGTol":   "0.05",
    # ±band around 1.0 for the ShinUpperIMU proj_g_ratio PASS verdict.
    # 0.30 → [0.7, 1.3]. Host-config emits the expanded band as two
    # env vars consumed by dma_launch.sh.
    "imuPitchRatioTol":  "0.30",
    "imuPairDeltaTol":   "0.20",
    # ── FIR-345 chirp test mode. `testMode: chirp` switches the diagnostic
    # node into the chirp/Bode sweep instead of joint-by-joint step/ramp.
    # All chirp* defaults mirror the dma_launch.sh defaults so a bare
    # `testMode: chirp` (no chirp-field overrides) works end-to-end.
    # The 12 fields below are inert when `testMode: joint-sweep` (default).
    "testMode":                 "joint-sweep",
    "chirpAmplitudeRad":        "0.05",
    "chirpAmplitudeHardCapRad": "0.30",
    "chirpFreqMinHz":           "0.05",
    "chirpFreqMaxHz":           "15.0",
    # Diagnostic control-loop push rate (Hz) for desired commands. "0.0"
    # (default) derives the rate from the observed /actuals dt (~50 Hz);
    # set explicitly (e.g. "200") to push faster. Important for chirp
    # fidelity: run at >= ~10x chirpFreqMaxHz to resolve the sweep
    # (50 Hz undersamples a 15 Hz chirp). Capped by the /actuals rate
    # (~500 Hz). Applies to both joint-sweep and chirp testMode.
    "cycleRateHz":              "0.0",
    "chirpDurationS":           "60.0",
    "chirpEnvelopeS":           "0.5",
    "chirpGainMultipliers":     "0.5,0.7,0.9,1.1,1.3,1.5",
    "chirpSettleVelTolRadS":    "0.02",
    "chirpSettleQuietS":        "0.5",
    "chirpSettleMaxS":          "10.0",
    "chirpRrdDir":              "/dev/shm",
    # Per-joint chirp amplitude overrides. Comma-separated NAME=VALUE list,
    # parallel in shape to `jointBiasOverrides` above. Operators paste the
    # precomputed 1/gear_ratio table from phantom-locomotion's static
    # reference JSON (docs/diagnostics/chirp_amplitudes_mk2_lower_body.json)
    # so each joint sees a mechanically-comparable command amplitude
    # regardless of its gearbox. Default empty (use the global
    # `chirpAmplitudeRad` for every joint). Inert when
    # `testMode: joint-sweep`. Mirrors jointBiasOverrides' omit-if-empty
    # behaviour so a bare diagnostic config doesn't ship a blank env var.
    "chirpAmplitudeOverrides": "",
    # CSV ladder of multipliers applied to baseline `position_kd` per
    # drive at each rung of the chirp sweep. Default "1.0" (single
    # rung, no Kd override) keeps existing chirp deployments unchanged.
    # For the Bode-tuning sweep, operators set the full ladder:
    #   positionKdMultipliers: "1.0,1.25,1.5,1.75,2.0"
    # When more than one value is given, the chirp test repeats the
    # full joint sweep at each Kd multiplier rung. Inert when
    # `testMode: joint-sweep`.
    "positionKdMultipliers":   "1.0",
}

# Map host-config camelCase field names -> environment-variable name set
# consumed by docker/dma_launch.sh.
DIAGNOSTIC_FIELD_TO_ENV: dict[str, str] = {
    "robot":        "LOCOMOTION_DIAGNOSTIC_ROBOT",
    "naming":       "LOCOMOTION_DIAGNOSTIC_NAMING",
    "bias":         "LOCOMOTION_DIAGNOSTIC_BIAS",
    "masterGain":   "LOCOMOTION_DIAGNOSTIC_MASTER_GAIN",
    "holdBiasS":    "LOCOMOTION_DIAGNOSTIC_HOLD_BIAS_S",
    "holdHomeS":    "LOCOMOTION_DIAGNOSTIC_HOLD_HOME_S",
    "joints":       "LOCOMOTION_DIAGNOSTIC_JOINTS",
    "outPath":      "LOCOMOTION_DIAGNOSTIC_OUT_PATH",
    "waitForStart": "LOCOMOTION_DIAGNOSTIC_WAIT_FOR_START",
    "jointBiasOverrides": "LOCOMOTION_DIAGNOSTIC_JOINT_BIAS_OVERRIDES",
    "iterations":         "LOCOMOTION_DIAGNOSTIC_ITERATIONS",
    # FIR-342 ramp + velocity tracking. The two band Lo/Hi env vars
    # consumed by dma_launch.sh are EMITTED from the single
    # `velTrackingRatioTol` field (see special handling below).
    "rampS":               "LOCOMOTION_DIAGNOSTIC_RAMP_S",
    "returnRampS":         "LOCOMOTION_DIAGNOSTIC_RETURN_RAMP_S",
    "velTrackingLagMaxMs": "LOCOMOTION_DIAGNOSTIC_VEL_TRACKING_LAG_MAX_MS",
    # FIR-341 IMU integrity tests. As with velTrackingRatioTol, the
    # `gravityMagTol` and `imuPitchRatioTol` fields each emit a
    # synthesized BAND_LO/BAND_HI env pair (see DIAGNOSTIC_TOL_TO_BAND).
    "skipImuTests":      "LOCOMOTION_DIAGNOSTIC_SKIP_IMU_TESTS",
    "gravityTol":        "LOCOMOTION_DIAGNOSTIC_GRAVITY_TOL",
    "gravityDriftTol":   "LOCOMOTION_DIAGNOSTIC_GRAVITY_DRIFT_TOL",
    "imuProjGXyTol":     "LOCOMOTION_DIAGNOSTIC_IMU_PROJ_G_XY_TOL",
    "imuPelvisYawTol":   "LOCOMOTION_DIAGNOSTIC_IMU_PELVIS_YAW_TOL",
    "imuQuatDeltaTol":   "LOCOMOTION_DIAGNOSTIC_IMU_QUAT_DELTA_TOL",
    "imuGyroNoiseFloor": "LOCOMOTION_DIAGNOSTIC_IMU_GYRO_NOISE_FLOOR",
    "imuIdleGyroTol":    "LOCOMOTION_DIAGNOSTIC_IMU_IDLE_GYRO_TOL",
    "imuIdleProjGTol":   "LOCOMOTION_DIAGNOSTIC_IMU_IDLE_PROJ_G_TOL",
    "imuPairDeltaTol":   "LOCOMOTION_DIAGNOSTIC_IMU_PAIR_DELTA_TOL",
    # FIR-345 chirp test mode. Routed to dma_launch.sh, which forwards
    # them to inference.dma_diagnostic_node's argparse.
    "testMode":                 "LOCOMOTION_DIAGNOSTIC_TEST_MODE",
    "chirpAmplitudeRad":        "LOCOMOTION_DIAGNOSTIC_CHIRP_AMPLITUDE_RAD",
    "chirpAmplitudeHardCapRad": "LOCOMOTION_DIAGNOSTIC_CHIRP_AMPLITUDE_HARD_CAP_RAD",
    "chirpFreqMinHz":           "LOCOMOTION_DIAGNOSTIC_CHIRP_FREQ_MIN_HZ",
    "chirpFreqMaxHz":           "LOCOMOTION_DIAGNOSTIC_CHIRP_FREQ_MAX_HZ",
    "cycleRateHz":              "LOCOMOTION_DIAGNOSTIC_CYCLE_RATE_HZ",
    "chirpDurationS":           "LOCOMOTION_DIAGNOSTIC_CHIRP_DURATION_S",
    "chirpEnvelopeS":           "LOCOMOTION_DIAGNOSTIC_CHIRP_ENVELOPE_S",
    "chirpGainMultipliers":     "LOCOMOTION_DIAGNOSTIC_CHIRP_GAIN_MULTIPLIERS",
    "chirpSettleVelTolRadS":    "LOCOMOTION_DIAGNOSTIC_CHIRP_SETTLE_VEL_TOL_RAD_S",
    "chirpSettleQuietS":        "LOCOMOTION_DIAGNOSTIC_CHIRP_SETTLE_QUIET_S",
    "chirpSettleMaxS":          "LOCOMOTION_DIAGNOSTIC_CHIRP_SETTLE_MAX_S",
    "chirpRrdDir":              "LOCOMOTION_DIAGNOSTIC_CHIRP_RRD_DIR",
    "chirpAmplitudeOverrides":  "LOCOMOTION_DIAGNOSTIC_CHIRP_AMPLITUDE_OVERRIDES",
    "positionKdMultipliers":    "LOCOMOTION_DIAGNOSTIC_POSITION_KD_MULTIPLIERS",
}

# Fields that expand from a single `tol` value into a (BAND_LO, BAND_HI)
# env pair: lo = 1 - tol, hi = 1 + tol. Keeps the host-config schema
# small while still letting the diagnostic node's argparse take an
# asymmetric pair. Operators almost always tune symmetrically; if you
# need asymmetric, edit dma_launch.sh defaults instead.
DIAGNOSTIC_TOL_TO_BAND: dict[str, tuple[str, str]] = {
    "velTrackingRatioTol": (
        "LOCOMOTION_DIAGNOSTIC_VEL_TRACKING_RATIO_BAND_LO",
        "LOCOMOTION_DIAGNOSTIC_VEL_TRACKING_RATIO_BAND_HI",
    ),
    "gravityMagTol": (
        "LOCOMOTION_DIAGNOSTIC_GRAVITY_MAG_BAND_LO",
        "LOCOMOTION_DIAGNOSTIC_GRAVITY_MAG_BAND_HI",
    ),
    "imuPitchRatioTol": (
        "LOCOMOTION_DIAGNOSTIC_IMU_PITCH_RATIO_BAND_LO",
        "LOCOMOTION_DIAGNOSTIC_IMU_PITCH_RATIO_BAND_HI",
    ),
}

# Diagnostic fields whose rendered ConfigMap value should be omitted
# entirely when the field is empty/blank, instead of emitting "KEY=".
# Avoids polluting the env with empty vars that the bash script then
# has to special-case.
DIAGNOSTIC_OMIT_IF_EMPTY: frozenset[str] = frozenset({
    "jointBiasOverrides",
    # FIR-342: when returnRampS is empty, dma_launch.sh lets the
    # diagnostic node's argparse default kick in (defaults to rampS,
    # symmetric ramp). Avoids forcing an explicit value in every
    # host-config when the symmetric default is fine.
    "returnRampS",
    # FIR-345 chirp: when chirpAmplitudeOverrides is empty, every joint
    # uses the global `chirpAmplitudeRad`. Mirrors jointBiasOverrides
    # so a bare diagnostic config doesn't ship a blank env var.
    "chirpAmplitudeOverrides",
})

# Diagnostic fields whose rendered ConfigMap value must be the
# lowercase string "true"/"false" so the in-pod bash check
# `[ "$X" = "true" ]` in dma_launch.sh matches directly. YAML scalar
# `true`/`false` parses to Python bool, which str()s to "True"/"False"
# (wrong); coerce here at the single emit site instead.
DIAGNOSTIC_BOOL_FIELDS: frozenset[str] = frozenset({
    "waitForStart",
    "skipImuTests",   # FIR-341 — gates the IMU verdict block on/off
})


# ── phantom-sonic (Walking ↔ SONIC) ────────────────────────────────────────
# Per-host knobs for the phantom-sonic DaemonSet, rendered into the
# phantom-sonic-config ConfigMap (envFrom'd by all four containers). Keys
# map host-config camelCase -> the env-var name each container consumes:
#   - ROS_DOMAIN_ID / SONIC_WALKING_POLICY / SONIC_ENCODER_MODE are read by
#     dma_launch.sh in the phantom-dma-inference containers (the latter two
#     via the manifest commands' "${VAR:-default}" shell-defaults).
#   - MOTION_ZMQ_PORT / CONTROL_ZMQ_PORT thread into the sonic container's
#     --motion-zmq / --control-zmq args.
#   - MOTION_ZMQ_PORT / WEB_PORT / MOTION_RAMP_SECS are the names fixed by
#     the phantom-motion-replay image.
# Defaults mirror AI/1134854145 and the manifest shell-defaults exactly so
# a bare (or absent) phantomSonic block renders a working ConfigMap.
DEFAULT_SONIC: dict[str, str] = {
    "rosDomainId":    "43",
    "walkingPolicy":  "mk1-walking-1imu-1",
    "encoderMode":    "0",
    "motionZmqPort":  "5557",
    "controlZmqPort": "5558",
    "webPort":        "7865",
    "motionRampSecs": "1.0",
}

SONIC_FIELD_TO_ENV: dict[str, str] = {
    "rosDomainId":    "ROS_DOMAIN_ID",
    "walkingPolicy":  "SONIC_WALKING_POLICY",
    "encoderMode":    "SONIC_ENCODER_MODE",
    "motionZmqPort":  "MOTION_ZMQ_PORT",
    "controlZmqPort": "CONTROL_ZMQ_PORT",
    "webPort":        "WEB_PORT",
    "motionRampSecs": "MOTION_RAMP_SECS",
}


def cmd_get_phantom_sonic_config_kv(cfg: dict) -> int:
    """Emit KEY=VALUE lines for the phantom-sonic-config ConfigMap.

    Operator overrides from the phantomSonic block are layered on top of
    DEFAULT_SONIC so the pod always has a complete set of knobs. Emitted in
    the stable order of DEFAULT_SONIC so the rendered ConfigMap diffs
    cleanly when one field changes. ASCII, no shell quoting — bootstrap's
    sonic-config phase drops each line into a YAML-quoted KEY: "VALUE".
    """
    block = cfg.get("phantomSonic") or {}
    if not isinstance(block, dict):
        print("error: 'phantomSonic' must be a mapping", file=sys.stderr)
        return 2

    merged: dict[str, object] = dict(DEFAULT_SONIC)
    for k, v in block.items():
        if k not in DEFAULT_SONIC:
            print(
                f"error: phantomSonic: unknown field {k!r} (permitted: "
                f"{sorted(DEFAULT_SONIC.keys())})",
                file=sys.stderr,
            )
            return 2
        if not isinstance(v, (str, int, float)) or isinstance(v, bool):
            print(
                f"error: phantomSonic.{k}: must be a scalar (str/int/float), "
                f"got {type(v).__name__}",
                file=sys.stderr,
            )
            return 2
        merged[k] = v

    lines = [
        f"{SONIC_FIELD_TO_ENV[field]}={merged[field]}"
        for field in DEFAULT_SONIC.keys()
    ]
    print("\n".join(lines))
    return 0


# ── phantom-psi (Ψ₀ VLA → locomotion) ──────────────────────────────────────
# Per-host knobs for the phantom-psi DaemonSet, rendered into the
# phantom-psi-config ConfigMap (envFrom'd by all three containers). Keys map
# host-config camelCase -> the env-var name each container consumes:
#   - PSI0_RUN_DIR / PSI0_CKPT_STEP / PSI0_CAMERA_ID / PSI0_STATE_QUEUE /
#     PSI0_ACTION_QUEUE / PSI0_INSTRUCTION thread into the psi0-vla container's
#     psi0_dma_runner args via the manifest command's "${VAR:-default}" shell-
#     defaults.
#   - ROS_DOMAIN_ID / PSI0_ACTION_QUEUE / PSI0_BRIDGE_RATE_HZ /
#     PSI0_ENABLE_{GAIT,HEIGHT,YAW} are read by the bridge container.
#   - ROS_DOMAIN_ID / POLICY_ONNX_PATH are read by the walking container.
# The loco passthrough flags default OFF (spec-004 AC-7 gating). Defaults
# mirror the manifest shell-defaults exactly so a bare (or absent) phantomPsi
# block renders a working ConfigMap.
DEFAULT_PSI: dict[str, str] = {
    "runDir":       "/models/full_task.real.flow1000.cosine.lr1.0e-04.b128.gpus1.2606120333",
    "ckptStep":     "120000",
    "cameraId":     "0",
    "stateQueue":   "psi0_state_j24",
    "actionQueue":  "psi0_actions_j24",
    "instruction":  "Grasp and lift part.",
    "rosDomainId":  "43",
    "bridgeRateHz": "50",
    "enableGait":   "0",
    "enableHeight": "0",
    "enableYaw":    "0",
    "walkingOnnx":  "/models/walking/policy.onnx",
}

PSI_FIELD_TO_ENV: dict[str, str] = {
    "runDir":       "PSI0_RUN_DIR",
    "ckptStep":     "PSI0_CKPT_STEP",
    "cameraId":     "PSI0_CAMERA_ID",
    "stateQueue":   "PSI0_STATE_QUEUE",
    "actionQueue":  "PSI0_ACTION_QUEUE",
    "instruction":  "PSI0_INSTRUCTION",
    "rosDomainId":  "ROS_DOMAIN_ID",
    "bridgeRateHz": "PSI0_BRIDGE_RATE_HZ",
    "enableGait":   "PSI0_ENABLE_GAIT",
    "enableHeight": "PSI0_ENABLE_HEIGHT",
    "enableYaw":    "PSI0_ENABLE_YAW",
    "walkingOnnx":  "POLICY_ONNX_PATH",
}


def cmd_get_phantom_psi_config_kv(cfg: dict) -> int:
    """Emit KEY=VALUE lines for the phantom-psi-config ConfigMap.

    Operator overrides from the phantomPsi block are layered on top of
    DEFAULT_PSI so the pod always has a complete set of knobs. Emitted in the
    stable order of DEFAULT_PSI so the rendered ConfigMap diffs cleanly when
    one field changes. ASCII, no shell quoting — bootstrap's psi-config phase
    drops each line into a YAML-quoted KEY: "VALUE".
    """
    block = cfg.get("phantomPsi") or {}
    if not isinstance(block, dict):
        print("error: 'phantomPsi' must be a mapping", file=sys.stderr)
        return 2

    merged: dict[str, object] = dict(DEFAULT_PSI)
    for k, v in block.items():
        if k not in DEFAULT_PSI:
            print(
                f"error: phantomPsi: unknown field {k!r} (permitted: "
                f"{sorted(DEFAULT_PSI.keys())})",
                file=sys.stderr,
            )
            return 2
        if not isinstance(v, (str, int, float)) or isinstance(v, bool):
            print(
                f"error: phantomPsi.{k}: must be a scalar (str/int/float), "
                f"got {type(v).__name__}",
                file=sys.stderr,
            )
            return 2
        merged[k] = v

    lines = [
        f"{PSI_FIELD_TO_ENV[field]}={merged[field]}"
        for field in DEFAULT_PSI.keys()
    ]
    print("\n".join(lines))
    return 0


def cmd_get_phantom_locomotion_policy(cfg: dict) -> int:
    """Print phantomLocomotion.policy or the documented default.
    Bootstrap's locomotion-config phase consumes this to render the
    LOCOMOTION_POLICY value into the phantom-locomotion-config CM."""
    block = cfg.get("phantomLocomotion") or {}
    if not isinstance(block, dict):
        print("error: 'phantomLocomotion' must be a mapping", file=sys.stderr)
        return 2
    policy = block.get("policy")
    if not policy:
        policy = DEFAULT_LOCOMOTION_POLICY
    print(policy)
    return 0


def cmd_get_phantom_locomotion_config_kv(cfg: dict) -> int:
    """Emit KEY=VALUE lines for the phantom-locomotion-config ConfigMap.

    Always emits LOCOMOTION_MODE and LOCOMOTION_POLICY. When
    mode == 'diagnostic', also emits one LOCOMOTION_DIAGNOSTIC_* line per
    field of the diagnostic subblock, with operator overrides merged on
    top of DEFAULT_LOCOMOTION_DIAGNOSTIC so the pod always has a complete
    set of knobs. Bootstrap's locomotion-config phase consumes this and
    renders one ConfigMap data: entry per line.

    Output is ASCII, no shell quoting, no comments — caller is expected
    to drop each line straight into a YAML-quoted `KEY: "VALUE"` entry.
    """
    block = cfg.get("phantomLocomotion") or {}
    if not isinstance(block, dict):
        print("error: 'phantomLocomotion' must be a mapping", file=sys.stderr)
        return 2

    mode = block.get("mode") or DEFAULT_LOCOMOTION_MODE
    if mode not in ALLOWED_LOCOMOTION_MODES:
        print(
            "error: phantomLocomotion.mode: must be one of "
            f"{sorted(ALLOWED_LOCOMOTION_MODES)} (got {mode!r})",
            file=sys.stderr,
        )
        return 2

    policy = block.get("policy") or DEFAULT_LOCOMOTION_POLICY

    lines: list[str] = [
        f"LOCOMOTION_MODE={mode}",
        f"LOCOMOTION_POLICY={policy}",
    ]

    if mode == "diagnostic":
        diag_override = block.get("diagnostic") or {}
        if not isinstance(diag_override, dict):
            print(
                "error: 'phantomLocomotion.diagnostic' must be a mapping",
                file=sys.stderr,
            )
            return 2
        merged: dict[str, str] = dict(DEFAULT_LOCOMOTION_DIAGNOSTIC)
        for k, v in diag_override.items():
            if k not in DEFAULT_LOCOMOTION_DIAGNOSTIC:
                print(
                    f"error: phantomLocomotion.diagnostic: unknown field "
                    f"{k!r} (permitted: "
                    f"{sorted(DEFAULT_LOCOMOTION_DIAGNOSTIC.keys())})",
                    file=sys.stderr,
                )
                return 2
            merged[k] = v
        # Emit in the stable order of DEFAULT_LOCOMOTION_DIAGNOSTIC so the
        # rendered ConfigMap diffs cleanly when one field changes.
        for field in DEFAULT_LOCOMOTION_DIAGNOSTIC.keys():
            raw = merged[field]
            # YAML bool -> Python bool; coerce to lowercase "true"/"false"
            # for fields whose in-pod consumer is a bash equality check.
            # All other scalar types (str/int/float) pass through str().
            if field in DIAGNOSTIC_BOOL_FIELDS and isinstance(raw, bool):
                value = "true" if raw else "false"
            else:
                value = str(raw)
            # Skip empty-valued fields whose in-pod consumer treats
            # "missing" and "empty" identically — keeps the ConfigMap
            # tidy in the common case where no overrides are set.
            if field in DIAGNOSTIC_OMIT_IF_EMPTY and value == "":
                continue
            # Tol fields synthesize a (BAND_LO, BAND_HI) env pair instead
            # of a single env. lo = 1 - tol, hi = 1 + tol. Single op-facing
            # knob; two-field operator-side API kept compatible with the
            # diagnostic node's argparse.
            if field in DIAGNOSTIC_TOL_TO_BAND:
                lo_env, hi_env = DIAGNOSTIC_TOL_TO_BAND[field]
                try:
                    tol = float(value)
                except ValueError:
                    print(
                        f"error: phantomLocomotion.diagnostic.{field}: "
                        f"expected float, got {value!r}",
                        file=sys.stderr,
                    )
                    return 2
                lines.append(f"{lo_env}={1.0 - tol:g}")
                lines.append(f"{hi_env}={1.0 + tol:g}")
                continue
            env_name = DIAGNOSTIC_FIELD_TO_ENV[field]
            lines.append(f"{env_name}={value}")

    print("\n".join(lines))
    return 0


def cmd_get_log_management_json(cfg: dict) -> int:
    """Emit the merged logManagement settings as JSON. Operator overrides
    are layered on top of LOG_MANAGEMENT_DEFAULTS so bootstrap can
    consume a single shape regardless of which fields the host-config
    actually sets. When the operator sets enabled: false, only that
    field is emitted (bootstrap interprets it as 'remove drop-ins')."""
    block = cfg.get("logManagement") or {}
    if block.get("enabled") is False:
        print(json.dumps({"enabled": False}))
        return 0
    merged = {
        "enabled": True,
        "journald": {
            **LOG_MANAGEMENT_DEFAULTS["journald"],
            **(block.get("journald") or {}),
        },
        "rsyslog": {
            **LOG_MANAGEMENT_DEFAULTS["rsyslog"],
            **(block.get("rsyslog") or {}),
        },
    }
    print(json.dumps(merged))
    return 0


def cmd_get_node_labels_json(cfg: dict) -> int:
    """Emit the nodeLabels: block as a flat JSON object, or {} if absent.
    Bootstrap consumes this to drive the foundation.bot/* reconcile
    loop in the cluster phase. The unconditional foundation.bot/robot
    label is added by bootstrap itself (NOT here) so this output stays
    a faithful representation of what the operator declared."""
    block = cfg.get("nodeLabels") or {}
    if not isinstance(block, dict):
        print("error: 'nodeLabels' must be a mapping", file=sys.stderr)
        return 2
    print(json.dumps(block))
    return 0


def cmd_get_node_label_defaults() -> int:
    """Emit the NODE_LABEL_REGISTRY as TSV `key\\tdefault\\tdescription`,
    one row per registered gate. Stateless — does not read host-config.

    Wizard (configure-host.sh) uses this to emit the nodeLabels: block
    with all known gates explicit; bootstrap-robot.sh's reconciler uses
    it to fill in defaults for keys the operator omitted.
    """
    for key, default, desc in NODE_LABEL_REGISTRY:
        print(f"{key}\t{default}\t{desc}")
    return 0


def cmd_get_cpu_isolation_json(cfg: dict) -> int:
    """Emit the cpuIsolation: block as JSON, or {} if absent. Bootstrap's
    cpu-isolation phase consumes this and renders /etc/cpusets.conf +
    drives manage_cpusets.sh subcommands."""
    block = cfg.get("cpuIsolation")
    if block is None:
        print("{}")
        return 0
    if not isinstance(block, dict):
        print("error: 'cpuIsolation' must be a mapping", file=sys.stderr)
        return 2
    print(json.dumps(block))
    return 0


def cmd_set_cpu_isolation_json(path: str, blob: str) -> int:
    """Persist a cpuIsolation block into the host-config file in place.
    Strips any existing top-level cpuIsolation: block and appends a
    fresh block at EOF. Comments and ordering elsewhere are preserved.

    Input is a JSON object — the same shape get-cpu-isolation-json
    emits (so an interactive prompt can build a dict, JSON-encode it,
    and round-trip through this command)."""
    p = Path(path)
    if not p.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 2
    try:
        block = json.loads(blob or "{}")
    except json.JSONDecodeError as exc:
        print(f"error: invalid JSON: {exc}", file=sys.stderr)
        return 2
    if not isinstance(block, dict):
        print("error: cpuIsolation must be a JSON object", file=sys.stderr)
        return 2

    src = p.read_text().splitlines(keepends=True)
    out: list[str] = []
    skipping = False
    for line in src:
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if skipping:
            if (
                indent == 0
                and stripped.strip()
                and not stripped.startswith("#")
            ):
                skipping = False
                out.append(line)
            continue
        if indent == 0 and stripped.startswith("cpuIsolation:"):
            skipping = True
            continue
        out.append(line)

    if out and not out[-1].endswith("\n"):
        out[-1] = out[-1] + "\n"
    out.append("cpuIsolation:\n")
    out.append(yaml.safe_dump({"_": block}, sort_keys=False)
               .split("_:\n", 1)[1])

    p.write_text("".join(out))
    return 0


# Registry of known containers addressable from host-config.yaml's
# `images:` block. Adding a new entry here is the entire change needed
# to make a new workload's image host-configurable.
#
#   stack:           which Application stack owns the workload — used by
#                    bootstrap to route the kustomize.images entry to
#                    that stack's per-host Application. None means the
#                    image is consumed directly by bootstrap (currently
#                    only dma-ethercat for the .deb installer Job).
#   manifest_image:  the image string the BASE manifest uses, sans tag.
#                    This is the find-key kustomize.images uses to
#                    locate and rewrite container references. The
#                    operator's `image:` value in host-config is the
#                    REPLACEMENT — bootstrap derives the kustomize
#                    string by combining this find-key with the
#                    operator's repo+tag.
CONTAINER_TARGETS: dict[str, dict[str, "str | None"]] = {
    "positronic-control": {
        "stack": "core",
        "manifest_image": "localhost:5443/positronic-control",
    },
    "phantom-models": {
        # Consumed by positronic-control's load-models initContainer.
        # Larger bundle (model weights, configs).
        "stack": "core",
        "manifest_image": "localhost:5443/phantom-models",
    },
    "phantom-policies": {
        # Consumed by phantom-locomotion's load-policies initContainer.
        # Slim image (~MB) — only ONNX policies, mapped to /models/policies.
        # Built from the same scripts/phantom-models/build.py with
        # `--image phantom-policies` and a manifest pointing entries at
        # dest: policies/<name>.
        "stack": "core",
        "manifest_image": "localhost:5443/phantom-policies",
    },
    "operator-ui": {
        "stack": "operator",
        "manifest_image": "foundationbot/argus.operator-ui",
    },
    "vr-web": {
        # Browser-based VR teleop UI (Quest 3 / WebXR). Lives in the
        # argus namespace alongside operator-ui. CI publishes
        # foundationbot/argus.vr.web.react:<branch> from the
        # argus.vr.web.react repo.
        "stack": "operator",
        "manifest_image": "foundationbot/argus.vr.web.react",
    },
    "voice-server": {
        # In-cluster Vosk recognizer fronting vr-web's /api/voice. CI
        # publishes foundationbot/argus.voice-server:<branch> from the
        # voice_server/ subdir of argus.vr.web.react.
        "stack": "operator",
        "manifest_image": "foundationbot/argus.voice-server",
    },
    "yovariable-server": {
        # DaemonSet bridging DMA shm IPC to network-accessible variable
        # endpoints. CI publishes foundationbot/yovariable-server:V-<x.y.z>-<ts>.
        "stack": "core",
        "manifest_image": "foundationbot/yovariable-server",
    },
    "dma-ethercat": {
        # Not stack-routed. Phase 9 reads images.dma-ethercat.image
        # directly to render the bootstrap-managed installer Job.
        "stack": None,
        "manifest_image": "foundationbot/dma-ethercat",
    },
    "phantom-locomotion": {
        # phantom-locomotion DaemonSet (foundation.bot/has-locomotion gated).
        # Container key tracks the workload name (matches DaemonSet name and
        # has-locomotion label); the published image is actually
        # foundationbot/phantom-dma-inference (built from
        # imu-policy/phantom-locomotion's docker/dma_policy/Dockerfile).
        # Same key/image indirection used by operator-ui (image
        # foundationbot/argus.operator-ui under key 'operator-ui').
        # CI publishes a -aarch64 variant for Jetson.
        "stack": "core",
        "manifest_image": "foundationbot/phantom-dma-inference",
    },
    "cpp-robot-state-estimator": {
        # State-estimator DaemonSet (foundation.bot/has-state-estimator).
        # CI publishes <branch>-latest-<arch> tags.
        "stack": "core",
        "manifest_image": "foundationbot/cpp-robot-state-estimator",
    },
    "ik-mk2": {
        # MK2 upper-body IK shim DaemonSet (foundation.bot/has-ik-mk2,
        # positronic ns). Key matches the DaemonSet + has-ik-mk2 label and
        # the published image repo (no key/image indirection). CI in the
        # IK_MK2 repo publishes a multi-arch manifest tag
        # foundationbot/ik-mk2:V-<x-y-z>-<ts> (per-arch -amd64/-arm64
        # siblings merged by the manifest job).
        "stack": "core",
        "manifest_image": "foundationbot/ik-mk2",
    },
    "phantom-motion-replay": {
        # motion-replay container of the phantom-sonic DaemonSet
        # (foundation.bot/has-sonic gated): web UI :7865 + ZMQ motion
        # streamer :5557, curated clips baked in at CI build. The other
        # three phantom-sonic containers (control/walking/sonic) run
        # foundationbot/phantom-dma-inference — rewritten via the existing
        # 'phantom-locomotion' key (same published image, mutually
        # exclusive workloads). CI publishes a -aarch64 variant for Jetson.
        "stack": "core",
        "manifest_image": "foundationbot/phantom-motion-replay",
    },
    "dma-streams": {
        # Single image, two DaemonSets — dma-recorder (has-recorder) and
        # rerun-streamer (has-streamer) — both run a different binary
        # from foundationbot/dma-streams. One CONTAINER_TARGETS entry
        # rewrites both via kustomize.images find-by-image-name.
        # CI publishes <branch>-latest-<arch> tags.
        "stack": "core",
        "manifest_image": "foundationbot/dma-streams",
    },
    "dma-bridge": {
        # Non-ROS WebSocket bridge (:9098) — the FE wire for
        # argus.vr.web.react. has-dma-bridge gated, default-on.
        # Key uses the hyphenated workload name (matches DaemonSet +
        # has-dma-bridge label); the published image repo is underscored
        # (foundationbot/dma_bridge) — same key/image indirection as
        # operator-ui and phantom-locomotion. CI in positronic_control
        # publishes <branch>-<arch> tags.
        "stack": "core",
        "manifest_image": "foundationbot/dma_bridge",
    },
    "okvis2x": {
        # okvis2x DaemonSet — OKVIS2-X live dense-stereo SLAM (has-okvis
        # gated, default-off). Multi-arch manifest: the aarch64 image is
        # the Jetson Thor build. OKVIS2-X CircleCI publishes :<branch> and
        # :latest (and immutable :<arch>-<version> on release tags).
        "stack": "core",
        "manifest_image": "foundationbot/okvis2x",
    },
    "okvis2x-models": {
        # Consumed by okvis2x's load-models initContainer — busybox bundle
        # of the SLAM model assets (~3.6 GB: SuperPoint/LightGlue
        # .onnx/.engine, depth/seg .pt, DBoW vocab), staged into a shared
        # emptyDir. Same load-models pattern as phantom-models. CircleCI's
        # build-models job content-addresses + publishes it.
        "stack": "core",
        "manifest_image": "foundationbot/okvis2x-models",
    },
    "as-inference": {
        # as-inference DaemonSet (foundation.bot/has-as-inference gated): the
        # action-solver z_ref consumer / /as_action producer. Base manifest
        # pins localhost:5443/as-inference:PLACEHOLDER; a host overrides it to
        # a real tag — local-registry retag or DockerHub repo-swap
        # (foundationbot/as-inference, via dockerhub-creds). MUST be
        # arm64/Thor; x86 fails CUDA init.
        "stack": "core",
        "manifest_image": "localhost:5443/as-inference",
    },
    "as-inference-models": {
        # Consumed by as-inference's load-models initContainer — busybox bundle
        # carrying the Thor-built TensorRT engines (dinov2 + per-task AS
        # engines) + PCA + norm-stats + state-machine + text-embeds + registry.
        # Image-only — an initContainer image, not a standalone workload, so it
        # has NO DEPLOYMENT_TARGETS entry. Arch-specific (arm64/Thor).
        "stack": "core",
        "manifest_image": "localhost:5443/as-inference-models",
    },
    "wm-inference": {
        # wm-inference DaemonSet (foundation.bot/has-wm-inference gated):
        # the world-model z_ref service. Base manifest pins
        # localhost:5443/wm-inference:PLACEHOLDER; a host overrides it to a
        # real tag — either a local-registry retag
        # (localhost:5443/wm-inference:<tag>) or a DockerHub repo-swap
        # (foundationbot/wm-inference:<tag>, pulled via dockerhub-creds).
        # The published image MUST be arm64/Thor (Dockerfile.thor); x86
        # fails CUDA init.
        "stack": "core",
        "manifest_image": "localhost:5443/wm-inference",
    },
    "wm-inference-models": {
        # Consumed by wm-inference's load-models initContainer — busybox
        # bundle carrying the Thor-built TensorRT engines + PCA + tokenizer
        # + registry, staged into a shared emptyDir. Same load-models
        # pattern as phantom-models / okvis2x-models. Arm64/Thor-specific
        # (the engines are arch- and TensorRT-version-bound). Image-only —
        # an initContainer image, not a standalone workload, so it has NO
        # DEPLOYMENT_TARGETS entry (nothing user-configurable to mount).
        "stack": "core",
        "manifest_image": "localhost:5443/wm-inference-models",
    },
    # wolverine-loco's three images all publish to ONE shared DockerHub repo
    # foundationbot/dma-ghost-wbc-inference, distinguished by tag prefix
    # (v / policies- / teleop-, +/-aarch64). To keep them independently
    # host-configurable despite the shared name, each container has a DISTINCT
    # localhost:5443/* find-key in manifests/base/wolverine-loco/ (pinned at
    # :PLACEHOLDER); a host overrides each via images: to the real shared repo +
    # its prefixed tag, and Kustomize find=replaces them independently (same
    # localhost-find-key -> foundationbot-override pattern as as-inference).
    "dma-ghost-wbc-node": {
        # wolverine-loco's 1 kHz pure-C++ inference node container.
        # e.g. images.dma-ghost-wbc-node.image: foundationbot/dma-ghost-wbc-inference:v0.1.0-aarch64
        "stack": "core",
        "manifest_image": "localhost:5443/dma-ghost-wbc-node",
    },
    "dma-ghost-wbc-policies": {
        # load-policies initContainer (ONNX carrier).
        # e.g. ...:policies-v0.1.0-aarch64
        "stack": "core",
        "manifest_image": "localhost:5443/dma-ghost-wbc-policies",
    },
    "dma-ghost-wbc-teleop": {
        # teleop web-UI sidecar (:8080).
        # e.g. ...:teleop-v0.1.0-aarch64
        "stack": "core",
        "manifest_image": "localhost:5443/dma-ghost-wbc-teleop",
    },
    "psi0-policy": {
        # psi0-vla container of the phantom-psi DaemonSet (foundation.bot/has-psi
        # gated): the Ψ₀ VLA GPU policy. Built on-device from
        # Psi0-VLA/infra/docker/Dockerfile.policy (MUST be a CUDA-13/sm_110 torch
        # base for Thor — the Orin igpu base does not run there). Currently a
        # LOCAL image (k0s containerd, not the fleet registry), so the in-repo
        # tag is the working default; kustomize rewrites it from
        # images.psi0-policy. TODO: publish to the registry for multi-robot.
        "stack": "core",
        "manifest_image": "psi0-policy",
    },
    "phantom-loco": {
        # bridge + walking containers of the phantom-psi DaemonSet. Local image
        # (bridge.psi0_loco_bridge + inference.policy_node). Rewritten from
        # images.phantom-loco. TODO: publish to the registry for multi-robot.
        "stack": "core",
        "manifest_image": "phantom-loco",
    },
}


def _split_image_ref(ref: str) -> tuple[str, str]:
    """Split 'foo/bar:tag' or 'host:port/foo/bar:tag' into
    (repo, tag). The tag is everything after the LAST colon, but only
    when that colon comes after the last slash (otherwise it's a
    registry port and there is no tag)."""
    last_slash = ref.rfind("/")
    last_colon = ref.rfind(":")
    if last_colon < 0 or last_colon < last_slash:
        raise ValueError(f"image ref {ref!r} has no tag")
    return ref[:last_colon], ref[last_colon + 1 :]


def _container_kustomize_string(cname: str, spec: dict) -> str:
    """Build the kustomize.images string for one container.
       repo == manifest_image (just retag) -> "manifest_image:tag"
       repo != manifest_image (swap repo)  -> "manifest_image=repo:tag"
    """
    target = CONTAINER_TARGETS[cname]
    manifest_image = target["manifest_image"]
    repo, tag = _split_image_ref(spec["image"])
    if repo == manifest_image:
        return f"{manifest_image}:{tag}"
    return f"{manifest_image}={repo}:{tag}"


def _images_dict(cfg: dict) -> dict:
    """Return the images: block as a dict, or {} if absent.
    Raises ValueError with a migration hint if the legacy list shape
    is detected. Callers should propagate the error string."""
    images = cfg.get("images")
    if images is None:
        return {}
    if isinstance(images, list):
        raise ValueError(
            "'images' is now a container-keyed mapping, not a list. "
            "Migrate to: 'images: { <container>: { image: <ref:tag> } }'. "
            "See host-config-templates/_template/host-config.yaml. "
            "Known containers: " + ", ".join(sorted(CONTAINER_TARGETS))
        )
    if not isinstance(images, dict):
        raise ValueError("'images' must be a mapping")
    return images


def cmd_get_images_json(cfg: dict) -> int:
    """Emit ALL kustomize.images entries derived from the images:
    block, as a compact JSON array. Container entries with stack=None
    (bootstrap-managed, e.g. dma-ethercat) are skipped — they are not
    routed to any Application's kustomize.images."""
    try:
        images = _images_dict(cfg)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    out: list[str] = []
    for cname, spec in images.items():
        if cname not in CONTAINER_TARGETS:
            print(
                f"error: images.{cname}: unknown container "
                f"(known: {', '.join(sorted(CONTAINER_TARGETS))})",
                file=sys.stderr,
            )
            return 2
        if not isinstance(spec, dict) or not spec.get("image"):
            continue
        if CONTAINER_TARGETS[cname]["stack"] is None:
            continue
        try:
            out.append(_container_kustomize_string(cname, spec))
        except ValueError as exc:
            print(f"error: images.{cname}: {exc}", file=sys.stderr)
            return 2
    print(json.dumps(out))
    return 0


def cmd_get_image_for_container(cfg: dict, container: str) -> int:
    """Echo the full image ref (repo:tag) for one container. Exit 1
    when the container is not overridden in host-config (caller can
    fall back to the manifest's default). Exit 2 on schema error."""
    if container not in CONTAINER_TARGETS:
        print(
            f"error: unknown container {container!r} "
            f"(known: {', '.join(sorted(CONTAINER_TARGETS))})",
            file=sys.stderr,
        )
        return 2
    try:
        images = _images_dict(cfg)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    spec = images.get(container)
    if not isinstance(spec, dict):
        return 1
    img = spec.get("image")
    if not img:
        return 1
    print(img)
    return 0


# Registry of known deployments addressable from /etc/phantomos/host-config.yaml's
# `deployments:` section. Adding a new entry here is the entire change
# needed to make a new workload's mounts host-configurable.
#
#   stack:     which Application stack owns this Deployment (used by
#              bootstrap to route the patch to phantomos-<robot>-<stack>)
#   kind:      Kubernetes resource kind for the strategic-merge target
#   namespace: the Deployment's namespace
#   container: the container name within the Pod template that the
#              volumeMounts list applies to
DEPLOYMENT_TARGETS: dict[str, dict[str, str]] = {
    "positronic-control": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "positronic-control",
    },
    "phantomos-api-server": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "api",
    },
    # phantom-locomotion DaemonSet — base manifest carries a default
    # /recordings mount sourced from /root/recordings on the host (same
    # path dma-recorder writes to). Robots whose recordings live on a
    # different partition (/data/recordings, /data2/recordings, …) can
    # override via:
    #
    #   deployments:
    #     phantom-locomotion:
    #       mounts:
    #         - {name: recordings, host: /data2/recordings, container: /recordings}
    #
    # Strategic-merge patches by volume `name`, so only the named mount
    # is replaced; shm / dev-input / policies stay as the base manifest
    # declares them. Operators can also add brand-new mounts (per-bench
    # logging dir, debug tooling, …) by listing them with fresh names.
    "phantom-locomotion": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "phantom-locomotion",
    },
    # cpp-robot-state-estimator DaemonSet — IMU + kinematic state estimator.
    # Override channels:
    #   * extraArgs: list of additional CLI flags appended after the base
    #     args (e.g. [--foot-contact-source, kinematic] on robots without
    #     F/T sensors, where the default ft_sensors contact source would
    #     disagree with the missing hardware). Append-only — base args are
    #     always re-emitted so strategic-merge replaces the whole list.
    #   * mounts: host-path overlays.
    "cpp-robot-state-estimator": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "state-estimator",
    },
    # DMA.streams recorder DaemonSet — patches go to the `recorder` container
    # (not the `janitor` sidecar). Override channels:
    #   * variant: mk1 | mk2 | mk2_lowerbody — picks the bundled URDF the
    #     recorder embeds into each .rrd via log_file_from_path. Required
    #     for the recorded file to render a robot when opened off-robot.
    #   * mounts: host-path overlays (e.g. redirect /recordings to /data2).
    "dma-recorder": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "recorder",
    },
    # DMA.streams live web visualization. Deployed but inert by default
    # (foundation.bot/has-streamer label not set). Override channels:
    #   * variant: mk1 | mk2 | mk2_lowerbody — picks the bundled URDF
    #     rerun_streamer loads. The image ships
    #     /usr/local/share/dma-streams/urdf/phantom_<v>.urdf for every
    #     variant; this knob just flips the --variant argv.
    #   * queueMemoryLimitMb: hard cap on the streamer's in-process
    #     AsyncLogQueue (drops oldest when over budget). Tight cap is
    #     the OOM-prevention knob.
    #   * mounts: host-path overlays (e.g. a custom URDF file).
    "rerun-streamer": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "streamer",
    },
    # dma-bridge DaemonSet — the FE WebSocket bridge over /dev/shm. The base
    # manifest declares only the universal /dev/shm mount; the bridge's
    # PYTHONPATH sibling repos (/src = positronic_control checkout,
    # /ai.inference) are per-host, so every robot supplies them via:
    #
    #   deployments:
    #     dma-bridge:
    #       privileged: true
    #       mounts:
    #         - {name: src,          host: /opt/positronic_control, container: /src}
    #         - {name: ai-inference, host: /opt/ai.inference,       container: /ai.inference}
    #
    # Same strategic-merge-by-volume-name mechanism positronic-control uses
    # for its /src mount.
    "dma-bridge": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "bridge",
    },
    # ik-mk2 DaemonSet — MK2 upper-body IK shim (positronic ns, default-off).
    # Override channels:
    #   * extraArgs: append CLI flags to the base args. The motivating case
    #     is per-host loop mode — a robot with no DMA master runs open-loop:
    #
    #       deployments:
    #         ik-mk2:
    #           extraArgs: [--no-actuals]
    #
    #     (also useful: [--log-level, DEBUG], or [--rate, "100"] — argparse
    #     last-wins, so a re-specified flag overrides the base value).
    #   * mounts: host-path overlays (the base manifest mounts only /dev/shm).
    "ik-mk2": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "ik-mk2",
    },
    # okvis2x DaemonSet — OKVIS2-X live dense-stereo SLAM. Override channels:
    #   * mounts: host-path overlays. The two common ones are a per-robot
    #     config dir (camera calibration differs per robot) and a persistent
    #     output dir (trajectories/meshes default to an ephemeral emptyDir):
    #
    #       deployments:
    #         okvis2x:
    #           mounts:
    #             - {name: okvis-config, host: /etc/phantomos/okvis, container: /etc/okvis}
    #             - {name: output,       host: /data/okvis,          container: /output}
    #           extraArgs: [dma_live, /etc/okvis/okvis_stereo_dense_thor.yaml,
    #                       /etc/okvis/se2.yaml, /output]
    #
    #   * extraArgs: REPLACES the container argv wholesale (the base manifest's
    #     args:). DEPLOYMENT_BASE_ARGS["okvis2x"] is empty, so extraArgs IS the
    #     full argv — first element is the app (dma_live | snetwork), then the
    #     config/output positionals. Repoint to the /etc/okvis mount above, or
    #     switch to snetwork dataset replay. Omit it to keep the baked Thor
    #     config the manifest ships.
    "okvis2x": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "okvis2x",
    },
    # wm-inference DaemonSet — world-model z_ref service (positronic ns,
    # has-wm-inference gated). Mounts-only override channel (no args: the
    # service is the image entrypoint, no DEPLOYMENT_BASE_ARGS entry). The
    # base manifest declares the universal /dev/shm + /dev + models mounts;
    # a robot can overlay extra host paths (e.g. a debug/log dir) by name.
    "wm-inference": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "wm-inference",
    },
    # as-inference DaemonSet — action-solver service (positronic ns,
    # has-as-inference gated). Mounts-only override channel (no args: the
    # service is the image entrypoint, no DEPLOYMENT_BASE_ARGS entry).
    "as-inference": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "positronic",
        "container": "as-inference",
    },
}


# Base args for argv-overlaying deployments. The strategic-merge patches
# emitted when host-config sets argv-shaped fields (variant,
# queueMemoryLimitMb, extraArgs) REPLACE args wholesale — strategic-merge
# cannot merge a list of scalar strings — so each entry below is the
# contract between host-config.py and the matching base manifest under
# manifests/base/. If a base manifest gains another flag, mirror it here
# so per-host overrides don't silently drop it.
#
# Each list is exactly what the manifest's `args:` contains EXCEPT for
# the fields we project from host-config (variant, queueMemoryLimitMb,
# extraArgs). Those are appended onto the base list when set.
RERUN_STREAMER_BASE_ARGS: list[str] = [
    # --bind + --port are the gRPC TARGET the streamer dials, NOT a bind
    # port. The dial URL is `rerun+http://<bind>:<port>/proxy`. With the
    # rerun-server colocated in the same pod (hostNetwork), 127.0.0.1:9877
    # is the server's gRPC ingest socket; 9788 is the browser-facing web
    # viewer (HTTP), which the streamer must NOT dial.
    #
    # Pre-2026-06-19 value was `--port 9788` — that pre-dated the
    # rerun-server sidecar and made the streamer dial the web port,
    # silently hanging the gRPC handshake. Keep this in sync with the
    # `--port` arg the rerun-server's `--port` value in
    # manifests/base/dma-streams/rerun-streamer.yaml.
    "--bind", "127.0.0.1",
    "--port", "9877",
    # --downsample sets the publish rate (every Nth frame from the 500 Hz
    # shm side). 25 → 20 Hz to Rerun. MUST live in BASE_ARGS rather than
    # only in the base manifest because any host that sets variant /
    # queueMemoryLimitMb / extraArgs triggers a full args replacement
    # (see _build_streamer_patch_args below), which would drop a
    # base-manifest-only flag silently. Keep this in sync with the
    # `--downsample` value in manifests/base/dma-streams/rerun-streamer.yaml.
    "--downsample", "25",
]
DMA_RECORDER_BASE_ARGS: list[str] = [
    "--output", "/recordings",
    "--max-duration", "60",
    "--max-size", "100",
    "--decimate", "1",
    "--manual-arm",
]
# MUST stay in sync with manifests/base/cpp-robot-state-estimator/
# state-estimator.yaml args:. If the base manifest gains or drops a
# flag, mirror the change here — otherwise extraArgs-bearing patches
# will silently restore the old arg list.
CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS: list[str] = [
    "--urdf", "/usr/local/share/phantom/urdf/20250206_phantom_mk1_clean.urdf",
    "--config", "/usr/local/share/phantom/config/state_estimator_params.json",
    "--mujoco-model", "/usr/local/share/phantom/config/mujoco/phantom_mk1.xml",
    "--body-frame-rotation", "enabled",
]
# MUST stay in sync with manifests/base/ik-mk2/ik-mk2.yaml args:. An
# extraArgs-bearing patch re-emits this whole list (strategic-merge can't
# merge scalar-string lists), then appends the operator's flags — so if the
# base manifest's args change, mirror them here or per-host overrides will
# silently restore the old list.
IK_MK2_BASE_ARGS: list[str] = [
    "--taskspace", "taskspace_command",
    "--command-out", "upper_body_cmd",
    "--rate", "50",
]
# okvis2x's argv is POSITIONAL (<app> <okvis.yaml> <se2.yaml> <output>) — there
# is nothing to append a flag to, so extraArgs is used as a WHOLESALE argv
# replacement rather than an append. Keeping the base empty makes the rendered
# args == extraArgs verbatim. The real default lives in the base manifest's
# args:; an operator who sets extraArgs is opting into specifying the full argv
# themselves (typically to repoint at a host-mounted per-robot config, or to
# switch to snetwork dataset replay).
OKVIS2X_BASE_ARGS: list[str] = []
DEPLOYMENT_BASE_ARGS: dict[str, list[str]] = {
    "rerun-streamer": RERUN_STREAMER_BASE_ARGS,
    "dma-recorder": DMA_RECORDER_BASE_ARGS,
    "cpp-robot-state-estimator": CPP_ROBOT_STATE_ESTIMATOR_BASE_ARGS,
    "ik-mk2": IK_MK2_BASE_ARGS,
    "okvis2x": OKVIS2X_BASE_ARGS,
}

# Allowlist for deployments.{rerun-streamer,dma-recorder}.variant. Add
# new entries as new URDFs ship in the DMA.streams image at
# /usr/local/share/dma-streams/urdf/phantom_<variant>.urdf.
#
#   mk1            — full-body mk1 URDF
#   mk2            — full-body mk2 URDF
#   mk2_lowerbody  — locomotion-only mk2 URDF (no Neck/Spine/Arms)
#                    Useful when only the lowerbody is relevant for the
#                    deployment, or when the upper body isn't physically
#                    populated yet. See foundationbot/DMA.streams FIR-320.
#
# The streamer auto-loads phantom_<variant>.urdf for live rendering;
# the recorder embeds the same URDF + meshes into each .rrd so the
# file is self-contained when opened off-robot.
ROBOT_VARIANTS: frozenset[str] = frozenset({"mk1", "mk2", "mk2_lowerbody"})
VARIANT_SUPPORTED_DEPLOYMENTS: frozenset[str] = frozenset({"rerun-streamer", "dma-recorder"})

# Allowlist for deployments.dma-recorder.explodeJoints. See FIR-329 in
# foundationbot/DMA.streams: bakes per-joint addressable Rerun entity
# paths (/joints/<quantity>/<category>/<JointName>) into the recording
# in addition to the bundled length-N Scalars entities. Without this,
# operators can't drag a single joint into its own viewer panel.
# Storage cost is a few MB per joint per minute; the sentinel "all"
# splits every joint (1.5–2× file growth — opt in deliberately).
# Only meaningful on dma-recorder.
EXPLODE_JOINTS_SUPPORTED_DEPLOYMENTS: frozenset[str] = frozenset({"dma-recorder"})

# Allowlist for deployments.<name>.extraArgs. A generic escape hatch for
# appending additional CLI flags to the deployment's base args without
# adding a named field per flag. Currently supported only on
# cpp-robot-state-estimator — the motivating case is robots without F/T
# sensors (e.g. mk11000009) that need --foot-contact-source kinematic
# instead of the default ft_sensors contact source.
EXTRA_ARGS_SUPPORTED_DEPLOYMENTS: frozenset[str] = frozenset(
    {"cpp-robot-state-estimator", "okvis2x", "ik-mk2"}
)


# Fields under a deployments.<name> entry that target the workload
# resource itself (volumes, container args, securityContext). Used by
# _deployment_spec_targets_workload below to decide whether the entry
# contributes a strategic-merge patch on the DaemonSet/Deployment.
# Fields outside this set (e.g. positronic-control's launchCommand,
# which patches the positronic-config ConfigMap instead) don't trigger
# an empty no-op patch on the workload.
_WORKLOAD_PATCH_FIELDS: frozenset[str] = frozenset({
    "mounts", "privileged", "variant", "queueMemoryLimitMb",
    "explodeJoints", "extraArgs",
    # Per-queue downsample overrides on rerun-streamer. Each becomes a
    # --<queue>-downsample N flag in the rendered DaemonSet args.
    "actualsDownsample", "actualsTransformsDownsample",
    "desiredDownsample", "desiredsControllerDownsample",
    "desiredsTransformsDownsample", "rawImuDownsample",
    "motorDiagnosticsDownsample", "stateEstimatorDownsample",
    "gripperDownsample",
})


def _deployment_spec_targets_workload(spec: dict) -> bool:
    """True iff this deployments.<name> entry has at least one field
    that produces a strategic-merge patch on the workload (DaemonSet /
    Deployment). Entries that only carry workload-adjacent fields like
    launchCommand (which patches the positronic-config ConfigMap) are
    treated as no-op for `_build_deployment_patch`."""
    return any(k in spec for k in _WORKLOAD_PATCH_FIELDS)


def _build_deployment_patch(
    deployment_name: str, spec: dict
) -> tuple[str, list[str]]:
    """Render a strategic-merge YAML patch for one entry under
    `deployments:`. Returns (patch_yaml, warnings)."""
    target = DEPLOYMENT_TARGETS[deployment_name]
    warnings: list[str] = []
    mounts = spec.get("mounts") or []
    privileged = bool(spec.get("privileged"))

    volumes: list[dict] = []
    volume_mounts: list[dict] = []

    seen_names: set[str] = set()
    for i, m in enumerate(mounts):
        if not isinstance(m, dict):
            raise ValueError(
                f"deployments.{deployment_name}.mounts[{i}] is not a mapping"
            )
        host = m.get("host")
        container = m.get("container")
        name = m.get("name") or f"mount-{i}"
        if not host or not container:
            raise ValueError(
                f"deployments.{deployment_name}.mounts[{i}] needs both "
                f"'host' and 'container'"
            )
        if name in seen_names:
            raise ValueError(
                f"deployments.{deployment_name}.mounts[{i}]: duplicate "
                f"volume name {name!r}"
            )
        seen_names.add(name)
        volumes.append({
            "name": name,
            "hostPath": {"path": host, "type": "DirectoryOrCreate"},
        })
        volume_mounts.append({"name": name, "mountPath": container})

    container_spec: dict = {
        "name": target["container"],
        "volumeMounts": volume_mounts,
    }
    if privileged:
        warnings.append(
            f"deployments.{deployment_name}.privileged=true — container "
            f"will run with full host access (/dev passthrough enabled)"
        )
        container_spec["securityContext"] = {"privileged": True}

    # Argv-overlay fields (variant, queueMemoryLimitMb, explodeJoints,
    # extraArgs, per-queue downsample overrides). When any of these are
    # set, strategic-merge REPLACES the whole args list, so we re-emit
    # the base manifest's args from DEPLOYMENT_BASE_ARGS and append the
    # overlay flags. validate() rejects each field on deployments where
    # it isn't supported.
    variant = spec.get("variant")
    queue_limit_mb = spec.get("queueMemoryLimitMb")
    explode_joints = spec.get("explodeJoints")
    extra_args = spec.get("extraArgs") or []
    # Per-queue downsample overrides for the streamer. Each maps a
    # YAML key (camelCase, matching the host-config schema) to a CLI
    # flag exposed by `rerun_streamer` in foundationbot/DMA.streams.
    # Adding a new queue here is a 1-line change.
    streamer_per_queue_downsamples = [
        ("actualsDownsample",             "--actuals-downsample"),
        ("actualsTransformsDownsample",   "--actuals-transforms-downsample"),
        ("desiredDownsample",             "--desired-downsample"),
        ("desiredsControllerDownsample",  "--desireds-controller-downsample"),
        ("desiredsTransformsDownsample",  "--desireds-transforms-downsample"),
        ("rawImuDownsample",              "--raw-imu-downsample"),
        ("motorDiagnosticsDownsample",    "--motor-diagnostics-downsample"),
        ("stateEstimatorDownsample",      "--state-estimator-downsample"),
        ("gripperDownsample",             "--gripper-downsample"),
    ]
    per_queue_overrides = [
        (flag, spec[key]) for key, flag in streamer_per_queue_downsamples
        if key in spec
    ]
    if (
        variant is not None
        or queue_limit_mb is not None
        or explode_joints
        or per_queue_overrides
        or extra_args
    ):
        base_args = DEPLOYMENT_BASE_ARGS.get(deployment_name)
        if base_args is None:
            # Defensive — validate() should have caught this. Skip silently
            # rather than emit a broken patch.
            pass
        else:
            args_out = list(base_args)
            if variant is not None:
                args_out += ["--variant", str(variant)]
            if queue_limit_mb is not None:
                args_out += ["--queue-memory-limit", str(queue_limit_mb)]
            # Append per-queue downsample overrides in the schema-list
            # order (deterministic for snapshot diffs). Each is a
            # streamer-only CLI flag; validate() rejects them elsewhere.
            for flag, value in per_queue_overrides:
                args_out += [flag, str(value)]
            if explode_joints:
                # Recorder's parser expects a single comma-joined string
                # ("SpineYaw,RightAnklePitch"), so flatten the list here.
                # The "all" sentinel passes through unchanged.
                args_out += ["--explode-joints", ",".join(str(n) for n in explode_joints)]
            if extra_args:
                # extraArgs is a list of additional flags to append verbatim
                # after the base args. validate() ensures each element is a
                # scalar (str/int/float/bool); coerce to str here so YAML
                # integers like port numbers pass through cleanly.
                args_out += [str(a) for a in extra_args]
            container_spec["args"] = args_out

    api_version = "apps/v1"
    patch = {
        "apiVersion": api_version,
        "kind": target["kind"],
        "metadata": {
            "name": deployment_name,
            "namespace": target["namespace"],
        },
        "spec": {
            "template": {
                "spec": {
                    "volumes": volumes,
                    "containers": [container_spec],
                }
            }
        },
    }
    return yaml.safe_dump(patch, sort_keys=False), warnings


# Target descriptor for the positronic-config ConfigMap that supplies
# PHANTOM_CMD to the positronic-control DaemonSet via envFrom. Lives in
# the `core` stack alongside the DaemonSet itself. Used by
# `deployments.positronic-control.launchCommand` (host-config.yaml) ->
# Argo kustomize.patches so the launch command becomes declarative
# (source-of-truth = host-config.yaml) and survives every Argo sync.
# See docs/internal/phantom-cmd-persistence.md.
POSITRONIC_CONFIGMAP_TARGET: dict[str, str] = {
    "stack": "core",
    "kind": "ConfigMap",
    "name": "positronic-config",
    "namespace": "positronic",
}


def _build_positronic_phantom_cmd_patch(value: str) -> str:
    """Render a strategic-merge YAML patch that stamps PHANTOM_CMD into
    the positronic-config ConfigMap. `value` is the operator-supplied
    launch command from
    host-config.yaml's `deployments.positronic-control.launchCommand`."""
    target = POSITRONIC_CONFIGMAP_TARGET
    patch = {
        "apiVersion": "v1",
        "kind": target["kind"],
        "metadata": {
            "name": target["name"],
            "namespace": target["namespace"],
        },
        # `data` is a strategic-merge map — kustomize merges by key, so
        # only PHANTOM_CMD is touched; ROS_DOMAIN_ID (and any other key)
        # falls through from the base ConfigMap.
        "data": {"PHANTOM_CMD": value},
    }
    return yaml.safe_dump(patch, sort_keys=False)


def cmd_get_deployment_patches_json(cfg: dict) -> int:
    """Emit a list of patch entries grouped by owning stack:
    [{"stack": "core", "patches": [{target, patch}, ...]}, ...].

    Bootstrap consumes this and assigns each stack's patch list to that
    stack's Application's spec.source.kustomize.patches. Stacks with no
    patches still appear with an empty list so consumers can clear
    previously-injected patches by setting kustomize.patches=[]."""
    deployments = cfg.get("deployments") or {}
    if not isinstance(deployments, dict):
        print("error: 'deployments' must be a mapping", file=sys.stderr)
        return 2

    # Initialize empty list per known stack so the output is symmetric.
    by_stack: dict[str, list[dict]] = {}
    for target in DEPLOYMENT_TARGETS.values():
        by_stack.setdefault(target["stack"], [])

    all_warnings: list[str] = []
    for name, spec in deployments.items():
        if name not in DEPLOYMENT_TARGETS:
            print(
                f"error: deployments.{name}: unknown deployment "
                f"(known: {', '.join(sorted(DEPLOYMENT_TARGETS))})",
                file=sys.stderr,
            )
            return 2
        if not spec:
            continue
        if not isinstance(spec, dict):
            print(
                f"error: deployments.{name}: must be a mapping",
                file=sys.stderr,
            )
            return 2
        # Skip entries that only carry workload-adjacent fields (e.g.
        # positronic-control with only launchCommand and no mounts). They
        # don't patch the DaemonSet/Deployment — launchCommand handled
        # separately below.
        if not _deployment_spec_targets_workload(spec):
            continue
        try:
            patch_yaml, warnings = _build_deployment_patch(name, spec)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        all_warnings.extend(warnings)
        target = DEPLOYMENT_TARGETS[name]
        by_stack[target["stack"]].append({
            "target": {
                "kind": target["kind"],
                "name": name,
                "namespace": target["namespace"],
            },
            "patch": patch_yaml,
        })

    # deployments.positronic-control.launchCommand — declarative
    # PHANTOM_CMD persistence. When set, emit a strategic-merge patch on
    # the positronic-config ConfigMap so the next Argo sync stamps
    # PHANTOM_CMD = <value> (instead of reverting it to "" from the base
    # manifest). When the field is absent, no patch is emitted — the
    # base manifest's `PHANTOM_CMD: ""` flows through and the DaemonSet
    # falls back to `sleep infinity` (legacy / dev-mode behavior).
    #
    # Lives nested under deployments.positronic-control alongside the
    # block's existing `mounts:` field so all positronic-control
    # deployment-side config sits together. (FIR-407 — moved here from a
    # top-level `positronic:` block, which only ever had this one field.)
    #
    # Operators can still override at runtime with
    # `positronic.sh set-cmd <cmd>`, but that patch is transient by
    # default unless the operator passes --transient: see FIR-408.
    pc_block = deployments.get("positronic-control") if isinstance(deployments, dict) else None
    if isinstance(pc_block, dict):
        launch_command = pc_block.get("launchCommand")
        if launch_command is not None:
            patch_yaml = _build_positronic_phantom_cmd_patch(str(launch_command))
            tgt = POSITRONIC_CONFIGMAP_TARGET
            by_stack.setdefault(tgt["stack"], []).append({
                "target": {
                    "kind": tgt["kind"],
                    "name": tgt["name"],
                    "namespace": tgt["namespace"],
                },
                "patch": patch_yaml,
            })

    for w in all_warnings:
        print(f"warning: {w}", file=sys.stderr)
    # Emit as a stable list-of-{stack,patches} so bash callers can
    # iterate predictably.
    out = [
        {"stack": stack, "patches": by_stack[stack]}
        for stack in sorted(by_stack)
    ]
    print(json.dumps(out))
    return 0


def cmd_get_enabled_stacks(cfg: dict) -> int:
    """Print one enabled stack name per line, in canonical order."""
    for name in KNOWN_STACKS:
        if _stack_enabled(cfg, name):
            print(name)
    return 0


def cmd_get_stack_selfheal(cfg: dict, stack: str) -> int:
    """Print 'true' or 'false' for the resolved selfHeal value."""
    if stack not in KNOWN_STACKS:
        print(f"error: unknown stack {stack!r} (known: {', '.join(KNOWN_STACKS)})",
              file=sys.stderr)
        return 2
    print("true" if _stack_selfheal(cfg, stack) else "false")
    return 0


def _kustomize_cmd() -> list[str] | None:
    """First available kustomize command on this host."""
    if shutil.which("kustomize"):
        return ["kustomize", "build"]
    if shutil.which("kubectl"):
        return ["kubectl", "kustomize"]
    if shutil.which("k0s"):
        return ["k0s", "kubectl", "kustomize"]
    return None


def _scan_stack_images(stacks_dir: str, stack: str) -> set[str]:
    """Run kustomize on manifests/stacks/<stack> and return the set of
    image references (registry/path, no tag/digest) used by any
    container in the rendered output."""
    cmd = _kustomize_cmd()
    if cmd is None:
        raise RuntimeError(
            "neither kustomize, kubectl, nor k0s available — cannot scan stacks"
        )
    target = f"{stacks_dir.rstrip('/')}/{stack}"
    try:
        out = subprocess.check_output([*cmd, target], stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"kustomize build failed for {target}: "
            f"{exc.stderr.decode(errors='replace').strip()}"
        )
    seen: set[str] = set()
    for doc in yaml.safe_load_all(out):
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"):
            pod = doc.get("spec", {}).get("template", {}).get("spec", {}) or {}
        elif kind == "Pod":
            pod = doc.get("spec", {}) or {}
        else:
            continue
        for c in (pod.get("containers") or []) + (pod.get("initContainers") or []):
            img = (c or {}).get("image", "") or ""
            if not img:
                continue
            # Strip tag/digest to keep just the registry/path/repo portion.
            if "@" in img:
                img = img.split("@", 1)[0]
            if img.count(":") >= 1 and not img.startswith("localhost:") \
               and ":" in img.rsplit("/", 1)[-1]:
                img = img.rsplit(":", 1)[0]
            elif img.startswith("localhost:") and img.count(":") >= 2:
                img = img.rsplit(":", 1)[0]
            seen.add(img)
    return seen


def cmd_inject_kustomize_block(
    cfg: dict, app_yaml_path: str, stack: str, stacks_dir: str
) -> int:
    """Read the rendered Application CR at app_yaml_path, compute
    spec.source.kustomize.{images,patches} for this stack from the
    host-config, and write the merged result back in place.

    images: filtered to those actually referenced by the stack's
    rendered manifests (kustomize-scan).
    patches: from host-config's `deployments:` block, routed by
    DEPLOYMENT_TARGETS to this stack."""
    p = Path(app_yaml_path)
    if not p.is_file():
        print(f"error: {app_yaml_path} not found", file=sys.stderr)
        return 2
    try:
        with p.open("r") as f:
            app = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        print(f"error: invalid YAML in {app_yaml_path}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(app, dict) or app.get("kind") != "Application":
        print(
            f"error: {app_yaml_path} is not an Application CR",
            file=sys.stderr,
        )
        return 2

    # Resolve images for this stack via kustomize-scan.
    try:
        stack_images = _scan_stack_images(stacks_dir, stack)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    # Filter host-config images to those owned by this stack.
    # Container-keyed schema: each entry is keyed by container name and
    # the registry tells us which stack it lives in. Cross-check
    # against the rendered manifest's actual image references — a
    # container whose manifest_image isn't found in the rendered output
    # is a hint that CONTAINER_TARGETS is stale, surface a stderr
    # warning so the operator notices.
    try:
        raw_images = _images_dict(cfg)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    images_block: list[str] = []
    image_warnings: list[str] = []
    for cname, spec in raw_images.items():
        if cname not in CONTAINER_TARGETS:
            image_warnings.append(
                f"images.{cname}: unknown container — ignored "
                f"(known: {', '.join(sorted(CONTAINER_TARGETS))})"
            )
            continue
        target = CONTAINER_TARGETS[cname]
        if target["stack"] != stack:
            continue
        if not isinstance(spec, dict) or not spec.get("image"):
            continue
        manifest_image = target["manifest_image"]
        if manifest_image not in stack_images:
            image_warnings.append(
                f"images.{cname}: manifest_image={manifest_image!r} not "
                f"referenced by any rendered {stack} manifest — registry "
                f"is stale (CONTAINER_TARGETS in host-config.py)"
            )
            continue
        try:
            images_block.append(_container_kustomize_string(cname, spec))
        except ValueError as exc:
            print(f"error: images.{cname}: {exc}", file=sys.stderr)
            return 2
    for w in image_warnings:
        print(f"warning: {w}", file=sys.stderr)

    # Build patches from `deployments:` filtered to this stack.
    patches_block: list[dict] = []
    deployments = cfg.get("deployments") or {}
    if not isinstance(deployments, dict):
        print("error: 'deployments' must be a mapping", file=sys.stderr)
        return 2
    warnings: list[str] = []
    for name, spec in deployments.items():
        if name not in DEPLOYMENT_TARGETS:
            continue
        target = DEPLOYMENT_TARGETS[name]
        if target["stack"] != stack:
            continue
        if not spec:
            continue
        if not isinstance(spec, dict):
            print(f"error: deployments.{name}: must be a mapping", file=sys.stderr)
            return 2
        # Skip entries that only carry workload-adjacent fields (e.g.
        # positronic-control with only launchCommand and no mounts). See
        # _deployment_spec_targets_workload for the gate.
        if not _deployment_spec_targets_workload(spec):
            continue
        try:
            patch_yaml, w = _build_deployment_patch(name, spec)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        warnings.extend(w)
        patches_block.append({
            "patch": patch_yaml,
            "target": {
                "kind": target["kind"],
                "name": name,
                "namespace": target["namespace"],
            },
        })

    # Also emit the positronic-config PHANTOM_CMD patch when this stack
    # owns it and host-config has
    # deployments.positronic-control.launchCommand set. Mirrors the
    # cmd_get_deployment_patches_json path. (FIR-407)
    if stack == POSITRONIC_CONFIGMAP_TARGET["stack"]:
        pc_block = deployments.get("positronic-control")
        if isinstance(pc_block, dict):
            launch_command = pc_block.get("launchCommand")
            if launch_command is not None:
                tgt = POSITRONIC_CONFIGMAP_TARGET
                patches_block.append({
                    "patch": _build_positronic_phantom_cmd_patch(
                        str(launch_command)
                    ),
                    "target": {
                        "kind": tgt["kind"],
                        "name": tgt["name"],
                        "namespace": tgt["namespace"],
                    },
                })

    # Inject under spec.source.kustomize. Preserve siblings in case the
    # template gains other kustomize keys later.
    spec_source = app.setdefault("spec", {}).setdefault("source", {})
    kust = spec_source.get("kustomize")
    if not isinstance(kust, dict):
        kust = {}
    kust["images"] = images_block
    kust["patches"] = patches_block
    spec_source["kustomize"] = kust

    with p.open("w") as f:
        yaml.safe_dump(app, f, sort_keys=False)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    # Report what landed so bootstrap can echo it.
    print(
        f"injected: stack={stack} images={len(images_block)} "
        f"patches={len(patches_block)}"
    )
    return 0


# Bundle manifest sidecar written by the image .deb's build script
# (RFC 0005). Hidden filename keeps it out of k0s's auto-import scan.
# When present, host-config.py validate cross-checks images.<container>.image
# against bundle[].ref and emits informational `note:` lines on drift —
# the operator's value still wins (host-config is the source of truth),
# notes are purely informational about expected operator overrides.
BUNDLE_MANIFEST_PATH = "/var/lib/k0s/images/.phantomos-image-bundle.yaml"


def _load_bundle_manifest(path: "str | None" = None) -> "dict | None":
    """Read and parse the bundle manifest. Returns None when the file is
    missing or unparseable — callers treat that as "no bundle, no
    cross-check" rather than an error. Older .debs predate the manifest;
    parse errors mean a corrupt sidecar that the wizard's separate arch
    check will already have flagged.

    Reads ``BUNDLE_MANIFEST_PATH`` from the module at call time (rather
    than capturing it as a default argument) so tests can rebind the
    module-level constant to a fixture path."""
    if path is None:
        path = BUNDLE_MANIFEST_PATH
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
    except (FileNotFoundError, yaml.YAMLError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def cmd_validate(cfg: dict) -> int:
    errors: list[str] = []
    notes: list[str] = []
    if not cfg.get("robot"):
        errors.append("'robot' is required")
    ai_pc = cfg.get("aiPcUrl") or ""
    if ai_pc and not (ai_pc.startswith("http://") or ai_pc.startswith("https://")):
        errors.append(f"'aiPcUrl' must start with http:// or https:// (got: {ai_pc!r})")
    target_rev = cfg.get("targetRevision") or ""
    if target_rev and not isinstance(target_rev, str):
        errors.append(f"'targetRevision' must be a string (got: {target_rev!r})")
    if "production" in cfg and not isinstance(cfg["production"], bool):
        errors.append(
            f"'production' must be true or false (got: {cfg['production']!r})"
        )

    # gitSource: optional top-level enum. RFC 0006 — selects between
    # local cluster-side git server and remote GitHub origin as the Argo
    # CD source. Defaults to 'local' when absent (set by cmd_get_git_source).
    git_source = cfg.get("gitSource")
    if git_source is not None:
        if not isinstance(git_source, str):
            errors.append("'gitSource' must be a string")
        elif git_source not in ("local", "remote"):
            errors.append(
                f"gitSource={git_source!r}: must be 'local' or 'remote'"
            )

    # Reject the legacy top-level `positronic:` block (FIR-407). The
    # field moved under deployments.positronic-control.launchCommand so
    # all positronic-control deployment-side config sits together.
    if "positronic" in cfg:
        errors.append(
            "'positronic' is no longer a top-level block (FIR-407). "
            "Move launchCommand under "
            "deployments.positronic-control.launchCommand. See "
            "host-config-templates/_template/host-config.yaml for the "
            "current schema."
        )

    # stacks: must be a mapping; only known stack names; required
    # stacks cannot be disabled; per-stack fields type-checked.
    stacks = cfg.get("stacks")
    if stacks is not None:
        if not isinstance(stacks, dict):
            errors.append("'stacks' must be a mapping of stack names to settings")
        else:
            for name, spec in stacks.items():
                if name not in KNOWN_STACKS:
                    errors.append(
                        f"stacks.{name}: unknown stack (known: {', '.join(KNOWN_STACKS)})"
                    )
                    continue
                if spec is None:
                    continue  # empty mapping = use defaults
                if not isinstance(spec, dict):
                    errors.append(f"stacks.{name}: must be a mapping")
                    continue
                if "enabled" in spec:
                    if not isinstance(spec["enabled"], bool):
                        errors.append(
                            f"stacks.{name}.enabled: must be true or false"
                        )
                    elif name in REQUIRED_STACKS and spec["enabled"] is False:
                        errors.append(
                            f"stacks.{name}.enabled: '{name}' is required and "
                            f"cannot be disabled — remove the field or set true"
                        )
                if "selfHeal" in spec and not isinstance(spec["selfHeal"], bool):
                    errors.append(f"stacks.{name}.selfHeal: must be true or false")
    # cpuIsolation is optional. Schema:
    #   enabled: bool
    #   partitions: list of {name: str, cpus: str, description?: str}
    #   nic: optional {iface: str, irqCore: int}
    #     (legacy alias `rtCore` accepted with a stderr warning)
    #   dmaRtCpu: int — core for the SOEM cyclic loop (DMA_RT_CPU).
    #     Should differ from nic.irqCore: the IRQ handler can preempt
    #     the loop at the wrong instant when they share a core. Equal
    #     values produce a stderr warning, not an error.
    #   installAffinityDefaults: bool (default true if cpuIsolation.enabled)
    #
    # NOTE: cpuIsolation.migrateCmdline (was opt-in under the cgroup-
    # partition approach) is dropped under RFC 0004 — kernel cmdline
    # editing is the primary mechanism and always-on. Validator
    # accepts the field for back-compat but ignores it.
    import re as _re
    _PART_NAME_RE = _re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
    _CPU_RANGE_RE = _re.compile(r"^\d+(-\d+)?(,\d+(-\d+)?)*$")

    def _expand_cpus(spec: str) -> set[int]:
        out: set[int] = set()
        for part in spec.split(","):
            if "-" in part:
                lo, hi = part.split("-", 1)
                a, b = int(lo), int(hi)
                if a > b:
                    raise ValueError(f"reversed range {part!r}")
                out.update(range(a, b + 1))
            else:
                out.add(int(part))
        return out

    ci = cfg.get("cpuIsolation")
    if ci is not None:
        if not isinstance(ci, dict):
            errors.append("'cpuIsolation' must be a mapping")
        else:
            if "enabled" in ci and not isinstance(ci["enabled"], bool):
                errors.append("cpuIsolation.enabled: must be true or false")
            for boolfield in ("installAffinityDefaults", "migrateCmdline"):
                if boolfield in ci and not isinstance(ci[boolfield], bool):
                    errors.append(
                        f"cpuIsolation.{boolfield}: must be true or false"
                    )
            # migrateCmdline is silently ignored under RFC 0004 — emit
            # a deprecation warning but don't fail validation so existing
            # host-configs from feat/cpu-isolation-bootstrap keep working.
            if "migrateCmdline" in ci:
                print(
                    "warning: cpuIsolation.migrateCmdline is deprecated under "
                    "RFC 0004 (kernel cmdline editing is always-on); the field "
                    "is ignored",
                    file=sys.stderr,
                )

            partitions = ci.get("partitions") or []
            if not isinstance(partitions, list):
                errors.append("cpuIsolation.partitions: must be a list")
                partitions = []
            seen_names: set[str] = set()
            seen_cpus: set[int] = set()
            for i, p in enumerate(partitions):
                label = f"cpuIsolation.partitions[{i}]"
                if not isinstance(p, dict):
                    errors.append(f"{label}: must be a mapping")
                    continue
                pname = p.get("name")
                if not pname or not isinstance(pname, str):
                    errors.append(f"{label}.name: required, must be a string")
                elif not _PART_NAME_RE.match(pname):
                    errors.append(
                        f"{label}.name={pname!r}: must be alnum/underscore "
                        f"(matches manage_cpusets.sh INI section rules)"
                    )
                elif pname in seen_names:
                    errors.append(f"{label}.name: duplicate {pname!r}")
                else:
                    seen_names.add(pname)
                cpus = p.get("cpus")
                if not cpus or not isinstance(cpus, str):
                    errors.append(f"{label}.cpus: required, must be a string")
                elif not _CPU_RANGE_RE.match(cpus):
                    errors.append(
                        f"{label}.cpus={cpus!r}: must match kernel cpu-list "
                        f"syntax (e.g. '10-13', '10,12', '10-11,13')"
                    )
                else:
                    try:
                        cpuset = _expand_cpus(cpus)
                    except ValueError as exc:
                        errors.append(f"{label}.cpus: {exc}")
                        cpuset = set()
                    overlap = cpuset & seen_cpus
                    if overlap:
                        errors.append(
                            f"{label}.cpus: overlaps existing partition on "
                            f"CPUs {sorted(overlap)}"
                        )
                    seen_cpus.update(cpuset)
                if "description" in p and not isinstance(p["description"], str):
                    errors.append(f"{label}.description: must be a string")

            nic = ci.get("nic")
            irq_core: int | None = None
            if nic is not None:
                if not isinstance(nic, dict):
                    errors.append("cpuIsolation.nic: must be a mapping")
                else:
                    iface = nic.get("iface")
                    if not iface or not isinstance(iface, str):
                        errors.append("cpuIsolation.nic.iface: required, must be a string")
                    # `irqCore` is canonical; `rtCore` is the deprecated
                    # name from before we split IRQ-pin from RT-loop core.
                    raw_irq = nic.get("irqCore")
                    raw_legacy = nic.get("rtCore")
                    field_name = "irqCore"
                    if raw_irq is None and raw_legacy is not None:
                        print(
                            "warning: cpuIsolation.nic.rtCore is deprecated, "
                            "use cpuIsolation.nic.irqCore instead "
                            "(this field pins the NIC's IRQs)",
                            file=sys.stderr,
                        )
                        raw_irq = raw_legacy
                        field_name = "rtCore"
                    elif raw_irq is not None and raw_legacy is not None:
                        errors.append(
                            "cpuIsolation.nic: set either irqCore or rtCore "
                            "(legacy), not both"
                        )
                    if raw_irq is None:
                        errors.append(
                            "cpuIsolation.nic.irqCore: required when nic block "
                            "present (bootstrap is non-interactive)"
                        )
                    elif not isinstance(raw_irq, int) or isinstance(raw_irq, bool):
                        errors.append(f"cpuIsolation.nic.{field_name}: must be an integer")
                    elif raw_irq not in seen_cpus:
                        errors.append(
                            f"cpuIsolation.nic.{field_name}={raw_irq}: not in any "
                            f"declared partition cpus ({sorted(seen_cpus) or 'none'})"
                        )
                    else:
                        irq_core = raw_irq

                    # selector — optional sub-block driving the
                    # one-time ecat-interface setup phase. Exactly one
                    # of {mac, pci, {driver,index}} must be set when
                    # the selector block is present.
                    sel = nic.get("selector")
                    if sel is not None:
                        if not isinstance(sel, dict):
                            errors.append("cpuIsolation.nic.selector: must be a mapping")
                        else:
                            keys_set = sum(
                                1 for k in ("mac", "pci", "driver") if sel.get(k)
                            )
                            if keys_set != 1:
                                errors.append(
                                    "cpuIsolation.nic.selector: set exactly one "
                                    "of mac, pci, or driver+index "
                                    "(got " + str(keys_set) + ")"
                                )
                            mac = sel.get("mac")
                            if mac is not None:
                                if not isinstance(mac, str) or not _re.match(
                                    r"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", mac
                                ):
                                    errors.append(
                                        "cpuIsolation.nic.selector.mac: must be "
                                        "aa:bb:cc:dd:ee:ff"
                                    )
                            pci = sel.get("pci")
                            if pci is not None:
                                if not isinstance(pci, str) or not _re.match(
                                    r"^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:"
                                    r"[0-9a-fA-F]{2}\.[0-9]$",
                                    pci,
                                ):
                                    errors.append(
                                        "cpuIsolation.nic.selector.pci: must be "
                                        "BDF format 0000:01:00.0"
                                    )
                            drv = sel.get("driver")
                            if drv is not None:
                                if not isinstance(drv, str) or not drv:
                                    errors.append(
                                        "cpuIsolation.nic.selector.driver: "
                                        "non-empty string required"
                                    )
                                idx = sel.get("index")
                                if idx is None:
                                    errors.append(
                                        "cpuIsolation.nic.selector.index: "
                                        "required when driver is set"
                                    )
                                elif (
                                    not isinstance(idx, int)
                                    or isinstance(idx, bool)
                                    or idx < 0
                                ):
                                    errors.append(
                                        "cpuIsolation.nic.selector.index: "
                                        "must be a non-negative integer"
                                    )

            # dmaRtCpu — top-level. Core where dma_main pins its
            # cyclic loop. Different from nic.irqCore by default.
            if "dmaRtCpu" in ci:
                rt_cpu = ci["dmaRtCpu"]
                if not isinstance(rt_cpu, int) or isinstance(rt_cpu, bool):
                    errors.append("cpuIsolation.dmaRtCpu: must be an integer")
                elif rt_cpu not in seen_cpus:
                    errors.append(
                        f"cpuIsolation.dmaRtCpu={rt_cpu}: not in any declared "
                        f"partition cpus ({sorted(seen_cpus) or 'none'})"
                    )
                elif irq_core is not None and rt_cpu == irq_core:
                    print(
                        f"warning: cpuIsolation.dmaRtCpu={rt_cpu} equals "
                        f"cpuIsolation.nic.irqCore — async NIC IRQs can "
                        f"preempt the SOEM RT loop. For minimum jitter, "
                        f"pick distinct cores inside the partition.",
                        file=sys.stderr,
                    )

            # (RFC 0004: migrateCmdline cross-validation removed —
            # cmdline editing is always-on.)

    # logManagement is optional; defaults are filled in by
    # cmd_get_log_management_json when fields are absent. Validation
    # is purely shape/type — no cross-field checks.
    lm = cfg.get("logManagement")
    if lm is not None:
        if not isinstance(lm, dict):
            errors.append("'logManagement' must be a mapping")
        else:
            _journald_size_re = _re.compile(r"^\d+(K|M|G|T)?$")
            _logrotate_size_re = _re.compile(r"^\d+(k|M|G)?$")
            if "enabled" in lm and not isinstance(lm["enabled"], bool):
                errors.append("logManagement.enabled: must be true or false")
            jd = lm.get("journald")
            if jd is not None:
                if not isinstance(jd, dict):
                    errors.append("logManagement.journald: must be a mapping")
                else:
                    for key in ("systemMaxUse", "systemMaxFileSize"):
                        val = jd.get(key)
                        if val is None:
                            continue
                        if not isinstance(val, str) or not _journald_size_re.match(val):
                            errors.append(
                                f"logManagement.journald.{key}: must match "
                                f"\\d+[KMGT]? (got {val!r})"
                            )
            rs = lm.get("rsyslog")
            if rs is not None:
                if not isinstance(rs, dict):
                    errors.append("logManagement.rsyslog: must be a mapping")
                else:
                    ms = rs.get("maxsize")
                    if ms is not None:
                        if not isinstance(ms, str) or not _logrotate_size_re.match(ms):
                            errors.append(
                                f"logManagement.rsyslog.maxsize: must match "
                                f"\\d+[kMG]? (got {ms!r})"
                            )
                    rot = rs.get("rotate")
                    if rot is not None:
                        if (
                            not isinstance(rot, int)
                            or isinstance(rot, bool)
                            or rot < 1
                        ):
                            errors.append(
                                f"logManagement.rsyslog.rotate: must be int >= 1 "
                                f"(got {rot!r})"
                            )
                    freq = rs.get("frequency")
                    if freq is not None and freq not in LOG_MANAGEMENT_VALID_FREQUENCIES:
                        errors.append(
                            f"logManagement.rsyslog.frequency: must be one of "
                            f"{sorted(LOG_MANAGEMENT_VALID_FREQUENCIES)} "
                            f"(got {freq!r})"
                        )
                    comp = rs.get("compress")
                    if comp is not None and not isinstance(comp, bool):
                        errors.append(
                            "logManagement.rsyslog.compress: must be true or false"
                        )

    # dmaEthercat is optional. configSet must be a single directory
    # name (no slashes, no '..') — bootstrap interpolates it into
    # /usr/share/dma-ethercat/config/<configSet>/<robot>.json, so
    # path separators would let an operator escape that directory.
    dma = cfg.get("dmaEthercat")
    if dma is not None:
        if not isinstance(dma, dict):
            errors.append("'dmaEthercat' must be a mapping")
        else:
            cset = dma.get("configSet")
            if cset is not None:
                if not isinstance(cset, str) or not cset:
                    errors.append("dmaEthercat.configSet: must be a non-empty string")
                elif "/" in cset or cset in (".", "..") or cset.startswith("."):
                    errors.append(
                        "dmaEthercat.configSet: must be a single directory "
                        "name (no '/', no leading '.')"
                    )
            cpath = dma.get("configPath")
            if cpath is not None:
                if not isinstance(cpath, str) or not cpath:
                    errors.append("dmaEthercat.configPath: must be a non-empty string")
                elif ".." in cpath.split("/"):
                    errors.append(
                        "dmaEthercat.configPath: '..' not allowed in path components"
                    )

    # images: is the container-keyed override map. Operators name the
    # container they want to retag/swap and supply the full image ref;
    # bootstrap looks up CONTAINER_TARGETS to find the manifest-side
    # name kustomize.images uses as its find-key.
    images_raw = cfg.get("images")
    if images_raw is not None:
        if isinstance(images_raw, list):
            errors.append(
                "'images' is now a container-keyed mapping, not a list. "
                "Migrate to: images: { <container>: { image: <ref:tag> } }. "
                "Known containers: " + ", ".join(sorted(CONTAINER_TARGETS))
            )
        elif not isinstance(images_raw, dict):
            errors.append("'images' must be a mapping")
        else:
            for cname, spec in images_raw.items():
                if cname not in CONTAINER_TARGETS:
                    errors.append(
                        f"images.{cname}: unknown container "
                        f"(known: {', '.join(sorted(CONTAINER_TARGETS))})"
                    )
                    continue
                if spec is None:
                    continue
                if not isinstance(spec, dict):
                    errors.append(f"images.{cname}: must be a mapping")
                    continue
                img = spec.get("image")
                if not img:
                    errors.append(f"images.{cname}.image: required")
                elif not isinstance(img, str):
                    errors.append(f"images.{cname}.image: must be a string")
                else:
                    try:
                        _, tag = _split_image_ref(img)
                    except ValueError as exc:
                        errors.append(f"images.{cname}.image: {exc}")
                    else:
                        # Reject wizard-placeholder tags. configure-host.sh
                        # used to write `REPLACE-WITH-*` strings as
                        # canonical defaults; pressing enter through the
                        # prompt left them in the file, and bootstrap
                        # phase 12 would dutifully inject them as
                        # kustomize.images overrides — guaranteeing
                        # ImagePullBackOff. See
                        # docs/image-flow-and-registry-bootstrap.md.
                        if tag.startswith("REPLACE-WITH-"):
                            errors.append(
                                f"images.{cname}.image: tag {tag!r} is a "
                                f"wizard placeholder; either set a real tag "
                                f"or remove the entry to use the manifest "
                                f"default"
                            )

            # Soft drift check against the bundle manifest sidecar
            # (RFC 0005 phase 5). The host-config is the authoritative
            # source of truth — operators may legitimately pin an older
            # ref or swap to an upstream registry — so disagreements with
            # the bundle are *expected* and don't fail validation. We
            # surface them as `note:` lines so that re-running validate
            # after a fresh `dpkg -i` of a new image .deb makes "operator
            # override active" visible at a glance.
            #
            # Skipped silently when the bundle manifest is absent or
            # unparseable; the wizard's bundle-arch and parse checks
            # already handle that path.
            bundle = _load_bundle_manifest()
            if bundle is not None:
                bundle_by_container: dict[str, str] = {}
                for entry in bundle.get("bundle") or []:
                    if not isinstance(entry, dict):
                        continue
                    bc = entry.get("container")
                    bref = entry.get("ref")
                    if isinstance(bc, str) and isinstance(bref, str) and bref:
                        bundle_by_container[bc] = bref
                for cname, spec in images_raw.items():
                    if cname not in CONTAINER_TARGETS:
                        continue  # already errored above
                    if not isinstance(spec, dict):
                        continue
                    img = spec.get("image")
                    if not isinstance(img, str) or not img:
                        continue
                    bref = bundle_by_container.get(cname)
                    if bref and bref != img:
                        notes.append(
                            f"images.{cname}.image={img} differs from "
                            f"bundle's {bref} — operator override active"
                        )

    # deployments is optional. Each key must be a known deployment.
    # Reject relative paths and '~' — bootstrap runs as root, so '~'
    # resolves to /root, which is almost never what the operator meant.
    deps = cfg.get("deployments") or {}
    if deps and not isinstance(deps, dict):
        errors.append("'deployments' must be a mapping")
    else:
        for name, spec in deps.items():
            if name not in DEPLOYMENT_TARGETS:
                errors.append(
                    f"deployments.{name}: unknown deployment "
                    f"(known: {', '.join(sorted(DEPLOYMENT_TARGETS))})"
                )
                continue
            if spec is None:
                continue
            if not isinstance(spec, dict):
                errors.append(f"deployments.{name}: must be a mapping")
                continue
            if "privileged" in spec and not isinstance(spec["privileged"], bool):
                errors.append(
                    f"deployments.{name}.privileged: must be true or false"
                )
            # variant: selects the bundled URDF the deployment loads
            # (rerun-streamer renders it live; dma-recorder embeds it
            # into each .rrd so the file is self-contained off-robot).
            if "variant" in spec:
                if name not in VARIANT_SUPPORTED_DEPLOYMENTS:
                    errors.append(
                        f"deployments.{name}.variant: only supported on "
                        f"{sorted(VARIANT_SUPPORTED_DEPLOYMENTS)}"
                    )
                else:
                    v = spec["variant"]
                    if not isinstance(v, str):
                        errors.append(
                            f"deployments.{name}.variant: must be a string"
                        )
                    elif v not in ROBOT_VARIANTS:
                        errors.append(
                            f"deployments.{name}.variant: {v!r} not in "
                            f"{sorted(ROBOT_VARIANTS)} — add the new "
                            f"variant to ROBOT_VARIANTS and ship the URDF "
                            f"in the dma-streams image first"
                        )
            # explodeJoints: list of joint names to also write as
            # per-joint Rerun entity paths (in addition to the bundled
            # length-N Scalars entities). See FIR-329 in DMA.streams.
            # The sentinel ["all"] splits every real joint. Only
            # meaningful on dma-recorder.
            if "explodeJoints" in spec:
                if name not in EXPLODE_JOINTS_SUPPORTED_DEPLOYMENTS:
                    errors.append(
                        f"deployments.{name}.explodeJoints: only "
                        f"supported on {sorted(EXPLODE_JOINTS_SUPPORTED_DEPLOYMENTS)}"
                    )
                else:
                    ej = spec["explodeJoints"]
                    if not isinstance(ej, list):
                        errors.append(
                            f"deployments.{name}.explodeJoints: must be a "
                            f"list of joint names (or ['all'] to split "
                            f"every joint)"
                        )
                    else:
                        for k, item in enumerate(ej):
                            if not isinstance(item, str) or not item.strip():
                                errors.append(
                                    f"deployments.{name}.explodeJoints[{k}]:"
                                    f" must be a non-empty string"
                                )
                                break
                            if "," in item or " " in item:
                                errors.append(
                                    f"deployments.{name}.explodeJoints[{k}]:"
                                    f" {item!r} must not contain ',' or "
                                    f"whitespace (recorder splits on commas)"
                                )
                                break
            # queueMemoryLimitMb: bounds rerun-streamer's in-process
            # AsyncLogQueue (drops oldest frames when over budget).
            # Tight cap is the OOM-prevention knob; only meaningful on
            # the live streamer.
            if "queueMemoryLimitMb" in spec:
                if name != "rerun-streamer":
                    errors.append(
                        f"deployments.{name}.queueMemoryLimitMb: only "
                        f"supported on rerun-streamer"
                    )
                else:
                    q = spec["queueMemoryLimitMb"]
                    if isinstance(q, bool) or not isinstance(q, int):
                        errors.append(
                            f"deployments.{name}.queueMemoryLimitMb: "
                            f"must be a positive integer (MB)"
                        )
                    elif q < 1:
                        errors.append(
                            f"deployments.{name}.queueMemoryLimitMb: "
                            f"must be >= 1 MB"
                        )
            # Per-queue downsample overrides on rerun-streamer. Each is
            # a non-negative integer; 0 means "inherit the global
            # --downsample". The list is kept in sync with the streamer's
            # CLI surface in foundationbot/DMA.streams; adding a new
            # queue here is a 1-line change.
            _PER_QUEUE_DOWNSAMPLE_FIELDS = (
                "actualsDownsample",
                "actualsTransformsDownsample",
                "desiredDownsample",
                "desiredsControllerDownsample",
                "desiredsTransformsDownsample",
                "rawImuDownsample",
                "motorDiagnosticsDownsample",
                "stateEstimatorDownsample",
                "gripperDownsample",
            )
            for field in _PER_QUEUE_DOWNSAMPLE_FIELDS:
                if field not in spec:
                    continue
                if name != "rerun-streamer":
                    errors.append(
                        f"deployments.{name}.{field}: only supported on "
                        f"rerun-streamer"
                    )
                    continue
                d = spec[field]
                if isinstance(d, bool) or not isinstance(d, int):
                    errors.append(
                        f"deployments.{name}.{field}: must be a non-"
                        f"negative integer (0 = inherit --downsample)"
                    )
                elif d < 0:
                    errors.append(
                        f"deployments.{name}.{field}: must be >= 0 "
                        f"(0 = inherit --downsample)"
                    )
            # extraArgs: generic append-only argv escape hatch. Supported
            # only on EXTRA_ARGS_SUPPORTED_DEPLOYMENTS (currently
            # cpp-robot-state-estimator). Must be a list of scalars
            # (strings, integers, floats). The motivating case is robots
            # without F/T sensors (e.g. mk11000009) that need
            # --foot-contact-source kinematic instead of the default
            # ft_sensors source.
            if "extraArgs" in spec:
                if name not in EXTRA_ARGS_SUPPORTED_DEPLOYMENTS:
                    errors.append(
                        f"deployments.{name}.extraArgs: only "
                        f"supported on {sorted(EXTRA_ARGS_SUPPORTED_DEPLOYMENTS)}"
                    )
                else:
                    ea = spec["extraArgs"]
                    if not isinstance(ea, list):
                        errors.append(
                            f"deployments.{name}.extraArgs: must be a "
                            f"list of strings"
                        )
                    else:
                        for k, item in enumerate(ea):
                            if isinstance(item, (dict, list)):
                                errors.append(
                                    f"deployments.{name}.extraArgs[{k}]:"
                                    f" must be a scalar (string, integer,"
                                    f" or float), got {type(item).__name__}"
                                )
                                break
            # launchCommand: declarative PHANTOM_CMD persistence (FIR-407).
            # Only meaningful on positronic-control; lives nested under
            # deployments alongside mounts: so all positronic-control
            # deployment-side config sits together. Emits a strategic-
            # merge patch on the positronic-config ConfigMap (not the
            # DaemonSet itself). See docs/internal/phantom-cmd-persistence.md.
            if "launchCommand" in spec:
                if name != "positronic-control":
                    errors.append(
                        f"deployments.{name}.launchCommand: only "
                        f"supported on positronic-control"
                    )
                else:
                    lc = spec["launchCommand"]
                    if lc is not None and not isinstance(lc, str):
                        errors.append(
                            f"deployments.{name}.launchCommand: must be "
                            f"a string (got: {lc!r})"
                        )
            mounts = spec.get("mounts") or []
            if not isinstance(mounts, list):
                errors.append(f"deployments.{name}.mounts: must be a list")
                continue
            seen_names: set[str] = set()
            for j, m in enumerate(mounts):
                label_base = f"deployments.{name}.mounts[{j}]"
                if not isinstance(m, dict):
                    errors.append(f"{label_base}: must be a mapping")
                    continue
                for required in ("host", "container"):
                    val = m.get(required)
                    if not val or not isinstance(val, str):
                        errors.append(f"{label_base}.{required}: required, must be a string")
                    elif val.startswith("~"):
                        errors.append(
                            f"{label_base}.{required}: '~' is not allowed "
                            f"(bootstrap runs as root, '~' becomes /root). "
                            f"Use the absolute path instead."
                        )
                    elif not val.startswith("/"):
                        errors.append(
                            f"{label_base}.{required}: must be an absolute "
                            f"path (got: {val!r})"
                        )
                vol_name = m.get("name")
                if vol_name is not None:
                    if not isinstance(vol_name, str):
                        errors.append(f"{label_base}.name: must be a string")
                    elif vol_name in seen_names:
                        errors.append(f"{label_base}.name: duplicate {vol_name!r}")
                    else:
                        seen_names.add(vol_name)

    # nodeLabels: optional flat mapping of k8s label key -> value.
    # Bootstrap reconciles the foundation.bot/* prefix from this block;
    # foundation.bot/robot is reserved (always 'true') and rejected here.
    nl = cfg.get("nodeLabels")
    if nl is not None:
        if not isinstance(nl, dict):
            errors.append("'nodeLabels' must be a mapping")
        else:
            for k, v in nl.items():
                if not isinstance(k, str) or not _K8S_LABEL_KEY_RE.match(k):
                    errors.append(
                        f"nodeLabels: key {k!r} not a valid k8s label key "
                        f"(prefix/name; alnum + - _ ., name max 63 chars)"
                    )
                if isinstance(k, str) and k in RESERVED_NODE_LABEL_KEYS:
                    errors.append(
                        f"nodeLabels.{k}: reserved — bootstrap always "
                        f"applies foundation.bot/robot=true unconditionally; "
                        f"remove this entry"
                    )
                if not isinstance(v, str):
                    errors.append(
                        f"nodeLabels.{k!r}: value must be a string (got "
                        f"{v!r}; YAML booleans like 'true' need to be quoted)"
                    )
                elif not _K8S_LABEL_VALUE_RE.match(v):
                    errors.append(
                        f"nodeLabels.{k}: value {v!r} not a valid k8s label "
                        f"value (alnum + - _ ., max 63 chars, can be empty)"
                    )

            # Mutual exclusion: positronic-control, phantom-locomotion,
            # phantom-sonic, and wolverine-loco are competing workloads —
            # each drives /desired, so at most ONE may be enabled per robot.
            # has-positronic defaults to "true" (the cluster phase
            # reconciler injects it on every robot unless explicitly set
            # false), so operators enabling locomotion / sonic / wolverine-loco
            # MUST also explicitly disable positronic — otherwise both would
            # render and fight for the robot.
            effective_pos = nl.get("foundation.bot/has-positronic", "true")
            effective_loc = nl.get("foundation.bot/has-locomotion", "false")
            effective_sonic = nl.get("foundation.bot/has-sonic", "false")
            effective_wloco = nl.get("foundation.bot/has-wolverine-loco", "false")
            effective_psi = nl.get("foundation.bot/has-psi", "false")
            effective_psi_dma = nl.get(
                "foundation.bot/has-psi-dma-walking", "false"
            )
            enabled_drivers = [
                label
                for label, eff in (
                    ("foundation.bot/has-positronic", effective_pos),
                    ("foundation.bot/has-locomotion", effective_loc),
                    ("foundation.bot/has-sonic", effective_sonic),
                    ("foundation.bot/has-wolverine-loco", effective_wloco),
                    ("foundation.bot/has-psi", effective_psi),
                    ("foundation.bot/has-psi-dma-walking", effective_psi_dma),
                )
                if eff == "true"
            ]
            if len(enabled_drivers) > 1:
                # Common case: operator turned on locomotion/sonic but left
                # the default-on positronic implicit. Point at the fix.
                if (
                    "foundation.bot/has-positronic" in enabled_drivers
                    and "foundation.bot/has-positronic" not in nl
                ):
                    other = [
                        d for d in enabled_drivers
                        if d != "foundation.bot/has-positronic"
                    ]
                    errors.append(
                        "nodeLabels: enabling "
                        f"{' and '.join(other)} requires explicitly setting "
                        "foundation.bot/has-positronic: \"false\" "
                        "(positronic defaults to on)"
                    )
                else:
                    errors.append(
                        "nodeLabels: the robot-driving workloads "
                        "foundation.bot/has-positronic, "
                        "foundation.bot/has-locomotion, "
                        "foundation.bot/has-sonic, "
                        "foundation.bot/has-wolverine-loco and "
                        "foundation.bot/has-psi are mutually exclusive — "
                        "only one may be \"true\" (got: "
                        f"{', '.join(enabled_drivers)})"
                    )

    # phantomLocomotion is optional; .policy must be a non-empty string
    # if present (a known policy name from the phantom-dma-inference
    # image's built-in registry — bootstrap doesn't enumerate them, the
    # in-pod dma_launch.sh fails loud if the value is unrecognized).
    # .mode is optional and gates between dma_policy_node ('policy') and
    # the wire-integrity diagnostic node ('diagnostic'); the diagnostic:
    # subblock supplies tunables for the latter (see FIR-337).
    pl = cfg.get("phantomLocomotion")
    if pl is not None:
        if not isinstance(pl, dict):
            errors.append("'phantomLocomotion' must be a mapping")
        else:
            policy = pl.get("policy")
            if policy is not None and (not isinstance(policy, str) or not policy):
                errors.append(
                    f"phantomLocomotion.policy: must be a non-empty string "
                    f"(got {policy!r})"
                )
            mode = pl.get("mode")
            if mode is not None:
                if not isinstance(mode, str) or mode not in ALLOWED_LOCOMOTION_MODES:
                    errors.append(
                        f"phantomLocomotion.mode: must be one of "
                        f"{sorted(ALLOWED_LOCOMOTION_MODES)} (got {mode!r})"
                    )
            diag = pl.get("diagnostic")
            if diag is not None:
                if not isinstance(diag, dict):
                    errors.append(
                        "phantomLocomotion.diagnostic: must be a mapping"
                    )
                else:
                    permitted = sorted(DEFAULT_LOCOMOTION_DIAGNOSTIC.keys())
                    for k, v in diag.items():
                        if k not in DEFAULT_LOCOMOTION_DIAGNOSTIC:
                            errors.append(
                                f"phantomLocomotion.diagnostic: unknown "
                                f"field {k!r} (permitted: {permitted})"
                            )
                            continue
                        # Scalars only — dict / list / None can't render
                        # cleanly into a ConfigMap data: entry.
                        if isinstance(v, bool) or isinstance(v, (str, int, float)):
                            continue
                        errors.append(
                            f"phantomLocomotion.diagnostic.{k}: must be a "
                            f"scalar (str/int/float/bool), got {type(v).__name__}"
                        )

    # phantomSonic is optional; every field is optional and falls back to
    # DEFAULT_SONIC. Reject unknown fields (typo guard) and non-scalars
    # (can't render into a ConfigMap data: entry). Same shape as the
    # phantomSonic merge in cmd_get_phantom_sonic_config_kv.
    ps = cfg.get("phantomSonic")
    if ps is not None:
        if not isinstance(ps, dict):
            errors.append("'phantomSonic' must be a mapping")
        else:
            permitted = sorted(DEFAULT_SONIC.keys())
            for k, v in ps.items():
                if k not in DEFAULT_SONIC:
                    errors.append(
                        f"phantomSonic: unknown field {k!r} "
                        f"(permitted: {permitted})"
                    )
                    continue
                if isinstance(v, bool) or not isinstance(v, (str, int, float)):
                    errors.append(
                        f"phantomSonic.{k}: must be a scalar (str/int/float), "
                        f"got {type(v).__name__}"
                    )

    # Notes are purely informational (e.g. host-config drift from bundle
    # sidecar). They're printed regardless of error/success — operators
    # want to see expected overrides whether or not validation passed —
    # and never affect the exit code.
    for n in notes:
        print(f"note: {n}", file=sys.stderr)
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 2
    print("ok")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: host-config.py <path> <get|get-images-json|validate> [field]", file=sys.stderr)
        return 2
    path, cmd = sys.argv[1], sys.argv[2]
    # Stateless commands: do not read host-config (the file may not
    # exist yet on a fresh host, e.g. during the wizard's initial run).
    if cmd == "get-node-label-defaults":
        return cmd_get_node_label_defaults()
    cfg = load(path)
    if cmd == "get":
        if len(sys.argv) != 4:
            print("usage: host-config.py <path> get <field>", file=sys.stderr)
            return 2
        return cmd_get(cfg, sys.argv[3])
    if cmd == "get-log-management-json":
        return cmd_get_log_management_json(cfg)
    if cmd == "get-node-labels-json":
        return cmd_get_node_labels_json(cfg)
    if cmd == "get-phantom-locomotion-policy":
        return cmd_get_phantom_locomotion_policy(cfg)
    if cmd == "get-phantom-locomotion-config-kv":
        return cmd_get_phantom_locomotion_config_kv(cfg)
    if cmd == "get-phantom-sonic-config-kv":
        return cmd_get_phantom_sonic_config_kv(cfg)
    if cmd == "get-phantom-psi-config-kv":
        return cmd_get_phantom_psi_config_kv(cfg)
    if cmd == "get-cpu-isolation-json":
        return cmd_get_cpu_isolation_json(cfg)
    if cmd == "set-cpu-isolation-json":
        if len(sys.argv) != 4:
            print(
                "usage: host-config.py <path> set-cpu-isolation-json <json>",
                file=sys.stderr,
            )
            return 2
        return cmd_set_cpu_isolation_json(path, sys.argv[3])
    if cmd == "get-images-json":
        return cmd_get_images_json(cfg)
    if cmd == "get-image-for-container":
        if len(sys.argv) != 4:
            print(
                "usage: host-config.py <path> get-image-for-container <container>",
                file=sys.stderr,
            )
            return 2
        return cmd_get_image_for_container(cfg, sys.argv[3])
    if cmd == "set-image":
        if len(sys.argv) != 5:
            print(
                "usage: host-config.py <path> set-image <container> <ref>",
                file=sys.stderr,
            )
            return 2
        return cmd_set_image(path, sys.argv[3], sys.argv[4])
    if cmd == "get-dma-ethercat-config-set":
        return cmd_get_dma_ethercat_config_set(cfg)
    if cmd == "get-dma-ethercat-config-path":
        return cmd_get_dma_ethercat_config_path(cfg)
    if cmd == "set-dma-ethercat-config-path":
        if len(sys.argv) != 4:
            print(
                "usage: host-config.py <path> set-dma-ethercat-config-path <value>",
                file=sys.stderr,
            )
            return 2
        return cmd_set_dma_ethercat_config_path(path, sys.argv[3])
    if cmd == "get-deployment-patches-json":
        return cmd_get_deployment_patches_json(cfg)
    if cmd == "set-positronic-launch-command":
        if len(sys.argv) != 4:
            print(
                "usage: host-config.py <path> "
                "set-positronic-launch-command <value>",
                file=sys.stderr,
            )
            return 2
        return cmd_set_positronic_launch_command(path, sys.argv[3])
    if cmd == "clear-positronic-launch-command":
        return cmd_clear_positronic_launch_command(path)
    if cmd == "get-enabled-stacks":
        return cmd_get_enabled_stacks(cfg)
    if cmd == "get-stack-selfheal":
        if len(sys.argv) != 4:
            print("usage: host-config.py <path> get-stack-selfheal <stack>", file=sys.stderr)
            return 2
        return cmd_get_stack_selfheal(cfg, sys.argv[3])
    if cmd == "get-git-source":
        return cmd_get_git_source(cfg)
    if cmd == "inject-kustomize-block":
        if len(sys.argv) != 6:
            print(
                "usage: host-config.py <path> inject-kustomize-block "
                "<app-yaml> <stack> <stacks-dir>",
                file=sys.stderr,
            )
            return 2
        return cmd_inject_kustomize_block(
            cfg, sys.argv[3], sys.argv[4], sys.argv[5]
        )
    if cmd == "validate":
        return cmd_validate(cfg)
    print(f"error: unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
