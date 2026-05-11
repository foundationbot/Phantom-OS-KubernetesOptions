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
  host-config.py <path> get-phantom-locomotion-policy
  host-config.py <path> get-images-json
  host-config.py <path> get-image-for-container <container>
  host-config.py <path> get-deployment-patches-json
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


DEFAULT_LOCOMOTION_POLICY: str = "mk2-walking-lower-body-1imu"


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
    "dma-streams": {
        # Single image, two DaemonSets — dma-recorder (has-recorder) and
        # rerun-streamer (has-streamer) — both run a different binary
        # from foundationbot/dma-streams. One CONTAINER_TARGETS entry
        # rewrites both via kustomize.images find-by-image-name.
        # CI publishes <branch>-latest-<arch> tags.
        "stack": "core",
        "manifest_image": "foundationbot/dma-streams",
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
    # DMA.streams recorder DaemonSet — patches go to the `recorder` container
    # (not the `janitor` sidecar). Typical override: redirect /recordings to
    # a dedicated data partition (e.g. /data2/recordings) on hosts where
    # /root sits on the OS disk.
    "dma-recorder": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "recorder",
    },
    # DMA.streams live web visualization. Deployed but inert by default
    # (foundation.bot/has-streamer label not set). Override channel here
    # is mainly for adding a URDF mount or swapping image tags per host.
    "rerun-streamer": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "streamer",
    },
}


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

            # Mutual exclusion: positronic-control and phantom-locomotion
            # are competing options. Operator picks one. has-positronic
            # defaults to "true" (the cluster phase reconciler injects
            # it on every robot unless explicitly set false), so
            # operators enabling locomotion MUST also explicitly disable
            # positronic — otherwise both would render and try to drive
            # the robot.
            effective_pos = nl.get("foundation.bot/has-positronic", "true")
            effective_loc = nl.get("foundation.bot/has-locomotion", "false")
            if effective_pos == "true" and effective_loc == "true":
                if "foundation.bot/has-positronic" not in nl:
                    errors.append(
                        "nodeLabels: enabling foundation.bot/has-locomotion "
                        "requires explicitly setting "
                        "foundation.bot/has-positronic: \"false\" "
                        "(positronic defaults to on)"
                    )
                else:
                    errors.append(
                        "nodeLabels: foundation.bot/has-positronic and "
                        "foundation.bot/has-locomotion are mutually "
                        "exclusive — only one may be \"true\""
                    )

    # phantomLocomotion is optional; .policy must be a non-empty string
    # if present (a known policy name from the phantom-dma-inference
    # image's built-in registry — bootstrap doesn't enumerate them, the
    # in-pod dma_launch.sh fails loud if the value is unrecognized).
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
