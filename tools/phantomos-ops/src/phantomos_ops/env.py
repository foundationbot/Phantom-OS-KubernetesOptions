"""Environment probe.

At app boot and on demand, fingerprint the host: which kubectl backend
is reachable, what the robot identity is, whether ArgoCD is up, etc.
The result drives action gating in the menu — entries whose
``requires:`` capabilities aren't met grey out with a reason rather
than running and failing mid-execution.

Design rules:
- Probes NEVER raise. A failed probe maps to ``available=False`` with
  a human-readable ``detail`` so the menu can show *why* something
  is gated.
- Results are memoized (5 s TTL) so the header bar redrawing on
  every keypress doesn't fork ``kubectl version`` 30 times a second.
- The probe runs synchronously on the main thread for now. If any
  individual check grows past ~50 ms we'll move it to a background
  worker; today's checks (file read, ``shutil.which``) are sub-ms.
"""
from __future__ import annotations

import os
import shutil
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path

# Resolved at import; tests monkeypatch this to a tmp path. Module-level
# attribute (not a constant baked into a default) so the patch actually
# takes effect.
_ROBOT_ID_PATH = Path("/etc/phantomos/robot")

_CACHE: tuple[float, "Fingerprint"] | None = None
_CACHE_TTL_S = 5.0


# Indirection so tests can monkeypatch lookup without touching $PATH.
def _which(name: str) -> str | None:
    return shutil.which(name)


@dataclass(frozen=True)
class Detection:
    """Outcome of probing for one capability.

    ``detail`` is always populated — when ``available`` is False it
    contains the reason; when True it contains the binary path or
    other identifying info.
    """
    available: bool
    detail: str


@dataclass(frozen=True)
class Fingerprint:
    """Snapshot of the host environment.

    The TUI's header bar reads from this; manifest action gating
    consults ``has_capability`` keyed by the strings used in
    ``requires:``. Frozen so it's safe to share across screens
    without defensive copies.
    """
    host: str
    robot_id: str          # may be "" — never None, callers don't need to guard
    kubectl: Detection
    root: Detection
    # Future capabilities will land here as their probes get added:
    # argocd, recorder_pod, etc. For M1 we ship the two that gate
    # most actions and grow the set in M2.

    def has_capability(self, name: str) -> bool:
        """Lookup used by the action gate. Unknown names → False so
        a manifest typo doesn't raise — operators see the action stay
        disabled and report it instead of crashing the app."""
        return getattr(self, name, Detection(False, "unknown capability")).available


def fingerprint(refresh: bool = False) -> Fingerprint:
    """Return a probed Fingerprint, possibly cached.

    Pass ``refresh=True`` to bypass the 5 s cache (used by the
    "manually re-probe" hotkey and by tests that change env state
    between calls).
    """
    global _CACHE
    now = time.monotonic()
    if not refresh and _CACHE is not None:
        when, fp = _CACHE
        if now - when < _CACHE_TTL_S:
            return fp

    fp = _probe()
    _CACHE = (now, fp)
    return fp


def _probe() -> Fingerprint:
    return Fingerprint(
        host=socket.gethostname(),
        robot_id=_read_robot_id(),
        kubectl=_probe_kubectl(),
        root=_probe_root(),
    )


def _read_robot_id() -> str:
    """Read /etc/phantomos/robot if it exists, else "".

    Does NOT fall back to hostname-mangling — robot id and node name
    can differ (e.g. node ``hw-thor01`` / robot ``hwthor01``); silent
    fallback would mask that.
    """
    try:
        return _ROBOT_ID_PATH.read_text().strip()
    except (FileNotFoundError, PermissionError, OSError):
        return ""


def _probe_kubectl() -> Detection:
    """Detect a kubectl backend.

    Prefers plain ``kubectl`` over ``k0s kubectl`` because operators
    on dev laptops have the former; on robots both are available and
    plain kubectl works the same. We don't actually call ``kubectl
    version`` here — that's a network round-trip; the mere presence
    of the binary is enough to enable the menu, and individual
    actions handle their own connection errors.
    """
    if (path := _which("kubectl")) is not None:
        return Detection(True, f"kubectl ({path})")
    if (path := _which("k0s")) is not None:
        return Detection(True, f"k0s kubectl ({path})")
    return Detection(False, "neither kubectl nor k0s found in PATH")


def _probe_root() -> Detection:
    if os.geteuid() == 0:
        return Detection(True, "running as root")
    return Detection(False, "needs root")
