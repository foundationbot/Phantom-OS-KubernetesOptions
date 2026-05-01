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


def cmd_validate(cfg: dict) -> int:
    errors: list[str] = []
    if not cfg.get("robot"):
        errors.append("'robot' is required")
    ai_pc = cfg.get("aiPcUrl") or ""
    if ai_pc and not (ai_pc.startswith("http://") or ai_pc.startswith("https://")):
        errors.append(f"'aiPcUrl' must start with http:// or https:// (got: {ai_pc!r})")
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
    if cmd == "validate":
        return cmd_validate(cfg)
    print(f"error: unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
