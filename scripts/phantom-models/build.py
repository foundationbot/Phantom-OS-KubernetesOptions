#!/usr/bin/env python3
"""Build and push the phantom-models container image.

The phantom-models image bundles model weights + configs into a
FROM-scratch OCI image. The positronic-control pod mounts it as a
read-only volume via the Kubernetes `image:` volume source (KEP-4639),
so the container never executes the image — it just reads files from
/models.

Three modes
-----------

1. **Default — interactive selection.** Prompts for a root directory
   (default: /root/phantom-models-merged), lists its top-level entries
   with sizes, and asks which to include. Each chosen entry lands at
   /models/<entry-name> in the resulting image.

       sudo python3 scripts/phantom-models/build.py

2. **--all — bundle the whole root tree** (no menu). Use --root to
   point at a different source. Equivalent to the old default.

       sudo python3 scripts/phantom-models/build.py --all

3. **--manifest FILE — explicit per-model selection** via a YAML file.
   Mutually exclusive with --all. Manifest format:

       models:
         - source: /path/to/sam2_hiera_large.pt
           dest: sam2_hiera_large.pt
         - source: /path/to/grounding-dino
           dest: grounding-dino

Tag defaults to today's date (YYYY-MM-DD) per the project's tag-scheme
decision (D-table in the plan doc). Override with --tag.

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
DEFAULT_ROOT = "/root/phantom-models-merged"

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


# ---------------------------------------------------------------------------
# Selection-parser logic — pure, testable.
# ---------------------------------------------------------------------------

def parse_selection(text: str, n: int) -> list[int]:
    """Convert a user's selection string to a list of zero-based indices.

    Accepts:
      - "all" → every index
      - "" or whitespace → empty list (caller treats this as "abort")
      - "1 3 5", "1,3,5", "1, 3, 5" → [0, 2, 4]

    Raises ValueError for non-numbers or out-of-range entries.

    >>> parse_selection("", 5)
    []
    >>> parse_selection("   ", 5)
    []
    >>> parse_selection("all", 3)
    [0, 1, 2]
    >>> parse_selection("ALL", 2)
    [0, 1]
    >>> parse_selection("1 3", 5)
    [0, 2]
    >>> parse_selection("1,3", 5)
    [0, 2]
    >>> parse_selection("  2  ,  4  ", 5)
    [1, 3]
    >>> try:
    ...     parse_selection("99", 3)
    ... except ValueError as e:
    ...     print("range error")
    range error
    >>> try:
    ...     parse_selection("a", 3)
    ... except ValueError as e:
    ...     print("number error")
    number error
    """
    text = text.strip().lower()
    if text == "all":
        return list(range(n))
    if not text:
        return []
    parts = text.replace(",", " ").split()
    indices: list[int] = []
    for p in parts:
        try:
            idx = int(p) - 1
        except ValueError:
            raise ValueError(f"not a number: {p!r}")
        if not (0 <= idx < n):
            raise ValueError(f"out of range (1..{n}): {p}")
        indices.append(idx)
    return indices


def human_size(path: Path) -> str:
    """Best-effort size estimate (bytes summed for directories)."""
    try:
        if path.is_file() and not path.is_symlink():
            b: float = path.stat().st_size
        else:
            b = 0.0
            for p in path.rglob("*"):
                try:
                    if p.is_file() and not p.is_symlink():
                        b += p.stat().st_size
                except (OSError, FileNotFoundError):
                    pass
    except (OSError, PermissionError):
        return "      ?"
    for unit in ["B", "K", "M", "G", "T"]:
        if b < 1024:
            return f"{b:6.1f}{unit}"
        b /= 1024
    return f"{b:6.1f}P"


# ---------------------------------------------------------------------------
# Interactive prompts.
# ---------------------------------------------------------------------------

def require_tty() -> None:
    if not sys.stdin.isatty():
        sys.exit(
            "stdin is not a TTY; cannot prompt interactively.\n"
            "Use --all (bundle whole tree), --manifest FILE (explicit YAML), "
            "or run from a terminal."
        )


def prompt_root(default: str) -> Path:
    """Ask the user where to scan for models. Re-asks on invalid input."""
    while True:
        try:
            raw = input(f"Scan which directory for models? [default: {default}]: ").strip()
        except EOFError:
            sys.exit("\naborted (EOF)")
        path = Path(raw or default)
        if not path.exists():
            print(f"  ! {path} does not exist; try again", file=sys.stderr)
            continue
        if not path.is_dir():
            print(f"  ! {path} is not a directory; try again", file=sys.stderr)
            continue
        return path.resolve()


def interactive_select(root: Path) -> list[Path]:
    """List top-level entries of root, prompt for selection, return chosen paths."""
    entries = sorted(p for p in root.iterdir() if not p.name.startswith("."))
    if not entries:
        sys.exit(f"{root} is empty")

    print(f"\nAvailable models in {root}:")
    print("(walking sizes — may take a few seconds)\n", file=sys.stderr)
    rows: list[tuple[int, Path, str]] = []
    for i, p in enumerate(entries, 1):
        rows.append((i, p, human_size(p)))

    name_width = max(len(p.name) + (1 if p.is_dir() else 0) for _, p, _ in rows)
    name_width = max(name_width, 24)
    for i, p, size in rows:
        suffix = "/" if p.is_dir() else ""
        print(f"  {i:2d}  {p.name + suffix:<{name_width}}  {size}")
    print()

    while True:
        try:
            sel = input(
                "Pick models (space/comma-separated, 'all', or blank to abort): "
            )
        except EOFError:
            sys.exit("\naborted (EOF)")
        try:
            idxs = parse_selection(sel, len(entries))
        except ValueError as exc:
            print(f"  ! {exc}; try again", file=sys.stderr)
            continue
        if not idxs:
            sys.exit("nothing selected, aborting")
        return [entries[i] for i in idxs]


def confirm(prompt: str) -> bool:
    try:
        ans = input(f"{prompt} [y/N]: ").strip().lower()
    except EOFError:
        return False
    return ans in ("y", "yes")


# ---------------------------------------------------------------------------
# Build/push.
# ---------------------------------------------------------------------------

def build_from_root(root: Path, image_ref: str, dry_run: bool) -> None:
    """`docker build` directly against the root directory. Zero-copy."""
    if not root.is_dir():
        sys.exit(f"--root is not a directory: {root}")
    print(f"==> Building {image_ref} from {root}", file=sys.stderr)
    run(
        ["docker", "build", "-f", str(DOCKERFILE), "-t", image_ref, str(root)],
        dry_run=dry_run,
    )


def build_from_entries(items: list[Path], image_ref: str, dry_run: bool) -> None:
    """Assemble a temp build context from chosen entries, then docker build."""
    with tempfile.TemporaryDirectory(prefix="phantom-models-build-") as ctx_str:
        ctx = Path(ctx_str)
        for src in items:
            target = ctx / src.name
            print(f"  copy {src} -> {target}", file=sys.stderr)
            if dry_run:
                continue
            if src.is_dir():
                shutil.copytree(src, target, symlinks=True, dirs_exist_ok=False)
            else:
                shutil.copy2(src, target)
        print(f"==> Building {image_ref} from {ctx}", file=sys.stderr)
        run(
            ["docker", "build", "-f", str(DOCKERFILE), "-t", image_ref, str(ctx)],
            dry_run=dry_run,
        )


def build_from_manifest(manifest_path: Path, image_ref: str, dry_run: bool) -> None:
    """Assemble a temp build context from explicit YAML entries."""
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
            ["docker", "build", "-f", str(DOCKERFILE), "-t", image_ref, str(ctx)],
            dry_run=dry_run,
        )


def push(image_ref: str, dry_run: bool) -> None:
    print(f"==> Pushing {image_ref}", file=sys.stderr)
    run(["docker", "push", image_ref], dry_run=dry_run)


def verify_in_registry(registry: str, image: str, tag: str) -> None:
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
        print(
            f"  warning: tag {tag} not in registry response: {body.strip()}",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# CLI.
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--all",
        action="store_true",
        help="Bundle the whole --root tree without prompting (no menu).",
    )
    mode.add_argument(
        "--manifest",
        help="YAML file with explicit source/dest entries (mutually exclusive with --all).",
    )
    p.add_argument(
        "--root",
        help=f"Directory to scan/bundle. If omitted, the default mode prompts "
             f"with a default of {DEFAULT_ROOT}.",
    )
    p.add_argument("--tag", default=today_tag(),
                   help="Image tag. Default: today's date (YYYY-MM-DD).")
    p.add_argument("--registry", default=DEFAULT_REGISTRY,
                   help=f"Registry host. Default: {DEFAULT_REGISTRY}")
    p.add_argument("--image", default=DEFAULT_IMAGE,
                   help=f"Image name. Default: {DEFAULT_IMAGE}")
    p.add_argument("--no-push", action="store_true", help="Build but do not push.")
    p.add_argument("--dry-run", action="store_true",
                   help="Print actions without executing.")
    p.add_argument("--yes", "-y", action="store_true",
                   help="Skip the proceed-with-build confirmation prompt.")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    image_ref = f"{args.registry}/{args.image}:{args.tag}"

    if args.manifest:
        build_from_manifest(Path(args.manifest), image_ref, args.dry_run)

    elif args.all:
        # Whole-tree bundle. Use --root if given, else default (no prompting
        # in --all mode — that flag means "skip the menu", and prompting for
        # a directory is a kind of menu).
        root = Path(args.root or DEFAULT_ROOT)
        build_from_root(root, image_ref, args.dry_run)

    else:
        # Default: interactive. Prompt for root if not given, then menu.
        require_tty()
        root = Path(args.root).resolve() if args.root else prompt_root(DEFAULT_ROOT)
        items = interactive_select(root)
        print()
        print(f"Selected {len(items)} item(s) under {root}:")
        for p in items:
            print(f"  - {p.name}{'/' if p.is_dir() else ''}")
        print()
        print(f"Tag:   {args.tag}")
        print(f"Image: {image_ref}")
        if not args.yes and not confirm("\nProceed with build"):
            sys.exit("aborted by user")
        build_from_entries(items, image_ref, args.dry_run)

    if not args.no_push:
        push(image_ref, args.dry_run)
        if not args.dry_run:
            verify_in_registry(args.registry, args.image, args.tag)

    print(f"\n==> Done: {image_ref}", file=sys.stderr)
    if not args.no_push:
        print("\nBump the tag in the per-robot patch:", file=sys.stderr)
        print("  manifests/robots/<robot>/patches/positronic-models-image.yaml",
              file=sys.stderr)
        print(f"    reference: {image_ref}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
