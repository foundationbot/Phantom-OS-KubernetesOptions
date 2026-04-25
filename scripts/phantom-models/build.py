#!/usr/bin/env python3
"""Build and push the phantom-models container image.

The phantom-models image bundles model weights + configs into a
FROM-scratch OCI image. The positronic-control pod mounts it as a
read-only volume via the Kubernetes `image:` volume source (KEP-4639),
so the container never executes the image — it just reads files from
/models.

See docs/plans/2026-04-24-positronic-k0s-migration.md §3.6a for the
full design and rollout context.

Two modes
---------

1. Single source directory (default; matches mk09's existing layout):

       sudo python3 scripts/phantom-models/build.py

   Bundles everything under /root/phantom-models-merged. Override the
   source with --source.

2. Explicit per-model selection via a YAML manifest:

       sudo python3 scripts/phantom-models/build.py --manifest models.yaml

   manifest format:
       models:
         - source: /path/to/sam2_hiera_large.pt
           dest: sam2_hiera_large.pt
         - source: /path/to/grounding-dino
           dest: grounding-dino

   Each entry's source (file or directory) is copied into a temp
   build context at the requested dest (relative to /models in the
   image). Use --manifest when you want a smaller, curated bundle
   instead of the whole models-merged tree.

Tag defaults to today's date in YYYY-MM-DD form per the project's
tag-scheme decision (D-table in the plan doc). Override with --tag.

The image is pushed to localhost:5443 by default; override with
--registry. Use --no-push to build locally without pushing.
"""

from __future__ import annotations

import argparse
import datetime
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

try:
    import yaml as _yaml
except ImportError:  # only required for --manifest
    _yaml = None

DEFAULT_REGISTRY = "localhost:5443"
DEFAULT_IMAGE = "phantom-models"
DEFAULT_SOURCE = "/root/phantom-models-merged"

# Dockerfile lives next to this script.
DOCKERFILE = Path(__file__).resolve().parent / "Dockerfile"


def today_tag() -> str:
    return datetime.date.today().strftime("%Y-%m-%d")


def run(cmd: list[str], dry_run: bool = False) -> None:
    """Echo a command and run it. Aborts the script on non-zero exit."""
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    if dry_run:
        return
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        sys.exit(f"command failed (exit {exc.returncode})")
    except FileNotFoundError:
        sys.exit(f"command not found: {cmd[0]}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    src_group = p.add_mutually_exclusive_group()
    src_group.add_argument(
        "--source",
        help=f"Directory whose contents become /models in the image. "
             f"Mutually exclusive with --manifest. Default: {DEFAULT_SOURCE}",
    )
    src_group.add_argument(
        "--manifest",
        help="YAML file with explicit source/dest entries.",
    )
    p.add_argument(
        "--tag",
        default=today_tag(),
        help="Image tag. Default: today's date (YYYY-MM-DD).",
    )
    p.add_argument(
        "--registry",
        default=DEFAULT_REGISTRY,
        help=f"Registry host. Default: {DEFAULT_REGISTRY}",
    )
    p.add_argument(
        "--image",
        default=DEFAULT_IMAGE,
        help=f"Image name. Default: {DEFAULT_IMAGE}",
    )
    p.add_argument(
        "--no-push",
        action="store_true",
        help="Build but do not push.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print actions without executing them.",
    )
    return p.parse_args()


def build_from_source(source: Path, image_ref: str, dry_run: bool) -> None:
    """`docker build` directly against the source directory.

    No copy is performed. The whole source becomes /models in the image.
    Best for the canonical /root/phantom-models-merged case.
    """
    if not source.is_dir():
        sys.exit(f"--source is not a directory: {source}")
    print(f"==> Building {image_ref} from {source}", file=sys.stderr)
    run(
        [
            "docker", "build",
            "-f", str(DOCKERFILE),
            "-t", image_ref,
            str(source),
        ],
        dry_run=dry_run,
    )


def build_from_manifest(manifest_path: Path, image_ref: str, dry_run: bool) -> None:
    """Assemble a temp build context from explicit entries, then `docker build`."""
    if _yaml is None:
        sys.exit(
            "PyYAML is required for --manifest.\n"
            "Install: pip install pyyaml  (or: apt install python3-yaml)"
        )
    spec = _yaml.safe_load(manifest_path.read_text()) or {}
    entries = spec.get("models") or []
    if not entries:
        sys.exit(f"manifest {manifest_path} has no 'models:' entries")

    with tempfile.TemporaryDirectory(prefix="phantom-models-build-") as ctx_str:
        ctx = Path(ctx_str)
        for entry in entries:
            src = Path(entry["source"]).resolve()
            dest_rel = entry["dest"].lstrip("/")
            if not src.exists():
                sys.exit(f"source does not exist: {src}")
            target = ctx / dest_rel
            target.parent.mkdir(parents=True, exist_ok=True)
            print(f"  copy {src} -> {target}", file=sys.stderr)
            if dry_run:
                continue
            if src.is_dir():
                shutil.copytree(src, target, symlinks=True, dirs_exist_ok=False)
            else:
                shutil.copy2(src, target)

        print(f"==> Building {image_ref} from {ctx}", file=sys.stderr)
        run(
            [
                "docker", "build",
                "-f", str(DOCKERFILE),
                "-t", image_ref,
                str(ctx),
            ],
            dry_run=dry_run,
        )


def push(image_ref: str, dry_run: bool) -> None:
    print(f"==> Pushing {image_ref}", file=sys.stderr)
    run(["docker", "push", image_ref], dry_run=dry_run)


def verify_in_registry(registry: str, image: str, tag: str) -> None:
    """Quick HTTP check that the registry actually has the new tag."""
    url = f"http://{registry}/v2/{image}/tags/list"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            body = resp.read().decode()
    except Exception as exc:
        print(f"  warning: could not query {url}: {exc}", file=sys.stderr)
        return
    if f'"{tag}"' in body:
        print(f"  registry confirms: {body.strip()}", file=sys.stderr)
    else:
        print(f"  warning: tag {tag} not in registry response: {body.strip()}", file=sys.stderr)


def main() -> int:
    args = parse_args()
    image_ref = f"{args.registry}/{args.image}:{args.tag}"

    if args.manifest:
        build_from_manifest(Path(args.manifest), image_ref, args.dry_run)
    else:
        source = Path(args.source) if args.source else Path(DEFAULT_SOURCE)
        build_from_source(source, image_ref, args.dry_run)

    if not args.no_push:
        push(image_ref, args.dry_run)
        if not args.dry_run:
            verify_in_registry(args.registry, args.image, args.tag)

    print(f"\n==> Done: {image_ref}", file=sys.stderr)
    if not args.no_push:
        print("\nBump the tag in the per-robot overlay:", file=sys.stderr)
        print("  manifests/robots/<robot>/kustomization.yaml", file=sys.stderr)
        print("    images:", file=sys.stderr)
        print(f"      - name: {args.registry}/{args.image}", file=sys.stderr)
        print(f"        newTag: {args.tag}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
