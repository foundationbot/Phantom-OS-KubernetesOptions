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
  host-config.py <path> get-dev-patches-json
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


def _build_dev_patch_for_positronic(spec: dict) -> tuple[str, list[str]]:
    """Render a strategic-merge YAML patch for the positronic-control
    Deployment from a `devMode.positronic-control` spec. Returns
    (patch_yaml, warnings)."""
    warnings: list[str] = []
    src = spec.get("source")
    mounts = spec.get("mounts") or []
    privileged = bool(spec.get("privileged"))

    volumes: list[dict] = []
    volume_mounts: list[dict] = []

    def _add(host_path: str, container_path: str, vol_name: str) -> None:
        volumes.append({
            "name": vol_name,
            "hostPath": {"path": host_path, "type": "DirectoryOrCreate"},
        })
        volume_mounts.append({"name": vol_name, "mountPath": container_path})

    if src:
        _add(src, "/src", "dev-src")

    for i, m in enumerate(mounts):
        if not isinstance(m, dict):
            raise ValueError(f"devMode mount[{i}] is not a mapping")
        host = m.get("host")
        container = m.get("container")
        if not host or not container:
            raise ValueError(
                f"devMode mount[{i}] needs both 'host' and 'container'"
            )
        # name must be DNS-1123: lowercase alnum + hyphens.
        name = f"dev-mount-{i}"
        _add(host, container, name)

    container_spec: dict = {
        "name": "positronic-control",
        "volumeMounts": volume_mounts,
    }
    if privileged:
        warnings.append(
            "devMode.positronic-control.privileged=true — container will run "
            "with full host access (/dev passthrough enabled)"
        )
        container_spec["securityContext"] = {"privileged": True}

    patch = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": "positronic-control", "namespace": "positronic"},
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


def cmd_get_dev_patches_json(cfg: dict) -> int:
    """Emit the kustomize.patches array (Argo Application format) as
    JSON, suitable for `kubectl patch app ... -p '{"spec":{"source":
    {"kustomize":{"patches":[...]}}}}'`. Empty array if devMode is
    unset — that explicitly clears any previously injected dev patches."""
    dev = cfg.get("devMode") or {}
    if not isinstance(dev, dict):
        print("error: 'devMode' must be a mapping", file=sys.stderr)
        return 2

    patches: list[dict] = []
    all_warnings: list[str] = []

    pos = dev.get("positronic-control")
    if pos:
        if not isinstance(pos, dict):
            print(
                "error: 'devMode.positronic-control' must be a mapping",
                file=sys.stderr,
            )
            return 2
        try:
            patch_yaml, warnings = _build_dev_patch_for_positronic(pos)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        all_warnings.extend(warnings)
        patches.append(
            {
                "target": {
                    "kind": "Deployment",
                    "name": "positronic-control",
                    "namespace": "positronic",
                },
                "patch": patch_yaml,
            }
        )

    for w in all_warnings:
        print(f"warning: {w}", file=sys.stderr)
    print(json.dumps(patches))
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

    # devMode is optional. Reject relative paths and ~ — bootstrap runs
    # as root, so ~ resolves to /root, which is almost never what the
    # operator meant.
    dev = cfg.get("devMode") or {}
    if dev and not isinstance(dev, dict):
        errors.append("'devMode' must be a mapping")
    else:
        for component, spec in dev.items():
            if not isinstance(spec, dict):
                errors.append(f"devMode.{component}: must be a mapping")
                continue
            paths_to_check: list[tuple[str, str]] = []
            src = spec.get("source")
            if src:
                paths_to_check.append((f"devMode.{component}.source", src))
            for j, m in enumerate(spec.get("mounts") or []):
                if isinstance(m, dict) and m.get("host"):
                    paths_to_check.append(
                        (f"devMode.{component}.mounts[{j}].host", m["host"])
                    )
            for label, p in paths_to_check:
                if not isinstance(p, str):
                    errors.append(f"{label}: must be a string")
                    continue
                if p.startswith("~"):
                    errors.append(
                        f"{label}: '~' is not allowed (bootstrap runs as root, "
                        f"~ becomes /root). Use the absolute path instead."
                    )
                elif not p.startswith("/"):
                    errors.append(
                        f"{label}: must be an absolute path (got: {p!r})"
                    )

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
    if cmd == "get-dev-patches-json":
        return cmd_get_dev_patches_json(cfg)
    if cmd == "validate":
        return cmd_validate(cfg)
    print(f"error: unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
