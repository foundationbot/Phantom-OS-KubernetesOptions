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
  host-config.py <path> get-images-json
  host-config.py <path> get-deployment-patches-json
  host-config.py <path> get-enabled-stacks            # one stack name per line
  host-config.py <path> get-stack-selfheal <stack>    # 'true' | 'false'
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


def cmd_get_images_json(cfg: dict) -> int:
    """Emit the images list as a compact JSON array suitable for
    `kubectl patch ... --type=merge -p '{"spec":{"source":{"kustomize":
    {"images":[...]}}}}'`. Argo Application's kustomize.images expects
    an array of strings of the form 'name=newName:newTag' OR the old
    'name:tag' form. We emit 'name:newTag' pairs."""
    images = cfg.get("images") or []
    if not isinstance(images, list):
        print("error: 'images' must be a list", file=sys.stderr)
        return 2
    out: list[str] = []
    for entry in images:
        if not isinstance(entry, dict):
            print(f"error: image entry not a mapping: {entry!r}", file=sys.stderr)
            return 2
        name = entry.get("name")
        new_tag = entry.get("newTag")
        new_name = entry.get("newName")
        if not name or not new_tag:
            print(
                f"error: image entry needs 'name' and 'newTag': {entry!r}",
                file=sys.stderr,
            )
            return 2
        # Argo accepts "name=newName:newTag" or "name:newTag". Use the
        # latter when newName is omitted (the common case).
        if new_name:
            out.append(f"{name}={new_name}:{new_tag}")
        else:
            out.append(f"{name}:{new_tag}")
    print(json.dumps(out))
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
        "kind": "Deployment",
        "namespace": "positronic",
        "container": "positronic-control",
    },
    "phantomos-api-server": {
        "stack": "core",
        "kind": "DaemonSet",
        "namespace": "phantom",
        "container": "api",
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


def cmd_validate(cfg: dict) -> int:
    errors: list[str] = []
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
    images = cfg.get("images") or []
    if not isinstance(images, list):
        errors.append("'images' must be a list")
    for i, entry in enumerate(images if isinstance(images, list) else []):
        if not isinstance(entry, dict):
            errors.append(f"images[{i}]: not a mapping")
            continue
        if not entry.get("name"):
            errors.append(f"images[{i}]: missing 'name'")
        if not entry.get("newTag"):
            errors.append(f"images[{i}]: missing 'newTag'")

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
    if cmd == "get-images-json":
        return cmd_get_images_json(cfg)
    if cmd == "get-deployment-patches-json":
        return cmd_get_deployment_patches_json(cfg)
    if cmd == "get-enabled-stacks":
        return cmd_get_enabled_stacks(cfg)
    if cmd == "get-stack-selfheal":
        if len(sys.argv) != 4:
            print("usage: host-config.py <path> get-stack-selfheal <stack>", file=sys.stderr)
            return 2
        return cmd_get_stack_selfheal(cfg, sys.argv[3])
    if cmd == "validate":
        return cmd_validate(cfg)
    print(f"error: unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
