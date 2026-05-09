"""Repo-root discovery.

When phantomos-ops runs from a source checkout, the repo lives a few
levels up from `__file__`. When it runs from a shiv zipapp, `__file__`
is inside ``/tmp/.shiv-*/site-packages/`` and tells us nothing about
where the operator's checkout is.

Manifest entries point at relative paths under ``scripts/`` — they
need that to resolve against the actual repo, not the zipapp cache.
This module finds the repo root via the first hit of:

    1. $PHANTOMOS_REPO if it points at a directory with the marker.
    2. cwd (and its parents) — the natural answer when the operator
       launches the binary from inside their checkout.
    3. A small list of common deployment paths.
    4. The source-tree relative path (works for `pipx install -e`).

The marker file is `manifests/stacks/core/kustomization.yaml` —
unique to this repo, present in every working tree, never likely to
move.

Failure to find it is surfaced as a clear error string from
``find_repo_root_or_error()`` rather than a path that points
somewhere wrong; the run-screen renders the error in its banner.
"""
from __future__ import annotations

import os
from pathlib import Path

_MARKER = Path("manifests") / "stacks" / "core" / "kustomization.yaml"

_COMMON_PATHS = (
    "/opt/Phantom-OS-KubernetesOptions",
    "/root/Phantom-OS-KubernetesOptions",
    "/root/foundation/DMA/Phantom-OS-KubernetesOptions",
    "/home/foundation/Phantom-OS-KubernetesOptions",
)


def _is_repo(path: Path) -> bool:
    try:
        return (path / _MARKER).is_file()
    except OSError:
        return False


def _walk_up(start: Path) -> Path | None:
    p = start.resolve()
    for candidate in (p, *p.parents):
        if _is_repo(candidate):
            return candidate
    return None


def find_repo_root() -> Path | None:
    """Best-effort repo-root resolution. Returns None if not found.

    Order:
      1. $PHANTOMOS_REPO
      2. cwd and ancestors
      3. well-known fleet paths
      4. source-tree fallback (works when installed via `pipx -e`)
    """
    env = os.environ.get("PHANTOMOS_REPO")
    if env:
        p = Path(env)
        if _is_repo(p):
            return p.resolve()

    found = _walk_up(Path.cwd())
    if found:
        return found

    for candidate in _COMMON_PATHS:
        p = Path(candidate)
        if _is_repo(p):
            return p.resolve()

    # Source-tree fallback: tools/phantomos-ops/src/phantomos_ops/repo.py
    # → six parents up is the repo root in an editable install.
    here = Path(__file__).resolve()
    if len(here.parents) >= 5:
        candidate = here.parents[4]
        if _is_repo(candidate):
            return candidate

    return None


def find_repo_root_or_error() -> tuple[Path | None, str | None]:
    """Return (root, None) on success or (None, error_msg) on failure.

    The error message names every place we looked so the operator
    can diagnose without reading the source.
    """
    root = find_repo_root()
    if root is not None:
        return root, None
    msg = (
        "could not locate the Phantom-OS-KubernetesOptions checkout.\n"
        "Set $PHANTOMOS_REPO, or run phantomos-ops from inside the\n"
        "checkout, or place it at one of:\n"
        + "\n".join(f"  {p}" for p in _COMMON_PATHS)
    )
    return None, msg
