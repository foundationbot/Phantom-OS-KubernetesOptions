#!/usr/bin/env bash
# install-image-bundle.sh — operator one-shot installer for the
# two-artifact phantomos-k0s-images bundle (RFC 0007 phase 3).
#
# The build pipeline emits a sibling pair per arch:
#
#   phantomos-k0s-images-<filename_version>-<arch>.deb       (~tens of KB,
#                                                             metadata only)
#   phantomos-k0s-images-<filename_version>-<arch>.tar.zst   (multi-GB sidecar
#                                                             of *.tar images)
#
# This wrapper takes the pair (or auto-discovers it in a directory),
# sanity-checks that the two filenames agree on version+arch and that
# the host's dpkg arch matches, extracts the sidecar at /, then runs
# `dpkg -i` on the .deb. The .deb's postinst (RFC 0007 phase 2) does
# the actual containerd import; this wrapper just lays the *.tar files
# under /var/lib/k0s/images/ first so the postinst's tarball-presence
# check passes.
#
# Usage:
#   sudo bash scripts/install-image-bundle.sh \
#     phantomos-k0s-images-<ver>-<arch>.deb \
#     phantomos-k0s-images-<ver>-<arch>.tar.zst
#
#   sudo bash scripts/install-image-bundle.sh /path/to/dir-with-both-files
#   sudo bash scripts/install-image-bundle.sh           # current dir
#
# Flags:
#   --dry-run        print what would happen, don't extract or dpkg -i
#   --skip-extract   skip the sidecar extract (operator extracted it
#                    manually, or an earlier run got partway and only
#                    the dpkg -i needs retrying)
#   -h, --help       this help
#
# Idempotency: this script is safe to re-run. Extracting the same
# .tar.zst twice overwrites identical bytes; `dpkg -i` of a
# same-version .deb is a no-op upgrade. Partial-failure recovery is
# the operator's job — re-run with --skip-extract if extraction
# already succeeded and only the dpkg step needs replaying.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DIR="/var/lib/k0s/images"
PKG_NAME="phantomos-k0s-images"

# ---- color/output helpers (match scripts/configure-host.sh style) ------

C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_RED=$'\033[31m'
C_RESET=$'\033[0m'

[ -t 1 ] || { C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_RED=""; C_RESET=""; }

heading() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET" >&2; }
info()    { printf '  %s\n' "${1:-}" >&2; }
hint()    { printf '%s  %s%s\n' "$C_DIM" "${1:-}" "$C_RESET" >&2; }
pass()    { printf '%s  ✓ %s%s\n' "$C_GREEN" "$1" "$C_RESET" >&2; }
warn()    { printf '%s  ! %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }
err()     { printf '%s  ✗ %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }
die()     { err "$1"; exit "${2:-1}"; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
}

# ---- arg parsing -------------------------------------------------------

DRY_RUN=0
SKIP_EXTRACT=0
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --skip-extract) SKIP_EXTRACT=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)             err "unknown flag: $1"; usage; exit 2 ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done

# ---- resolve $DEB_PATH and $SIDECAR_PATH from positional args ---------

DEB_PATH=""
SIDECAR_PATH=""

resolve_from_dir() {
  local dir="$1"
  [ -d "$dir" ] || die "not a directory: $dir"

  local debs=() sidecars=()
  while IFS= read -r -d '' f; do debs+=("$f"); done \
    < <(find "$dir" -maxdepth 1 -type f -name "${PKG_NAME}-*.deb" -print0 2>/dev/null)
  while IFS= read -r -d '' f; do sidecars+=("$f"); done \
    < <(find "$dir" -maxdepth 1 -type f -name "${PKG_NAME}-*.tar.zst" -print0 2>/dev/null)

  if [ "${#debs[@]}" -eq 0 ]; then
    die "no ${PKG_NAME}-*.deb found in $dir"
  elif [ "${#debs[@]}" -gt 1 ]; then
    err "multiple ${PKG_NAME}-*.deb files found in $dir:"
    local d; for d in "${debs[@]}"; do info "  $d"; done
    die "pass the .deb path explicitly to disambiguate"
  fi

  if [ "${#sidecars[@]}" -eq 0 ]; then
    die "no ${PKG_NAME}-*.tar.zst found in $dir"
  elif [ "${#sidecars[@]}" -gt 1 ]; then
    err "multiple ${PKG_NAME}-*.tar.zst files found in $dir:"
    local s; for s in "${sidecars[@]}"; do info "  $s"; done
    die "pass the .tar.zst path explicitly to disambiguate"
  fi

  DEB_PATH="${debs[0]}"
  SIDECAR_PATH="${sidecars[0]}"
}

case "${#POSITIONAL[@]}" in
  0)
    # Default: auto-discover in current directory.
    resolve_from_dir "$PWD"
    ;;
  1)
    # One arg: must be a directory we auto-discover in.
    if [ -d "${POSITIONAL[0]}" ]; then
      resolve_from_dir "${POSITIONAL[0]}"
    else
      die "single arg must be a directory; got non-directory: ${POSITIONAL[0]}"
    fi
    ;;
  2)
    # Two args: figure out which is which from the suffix.
    for arg in "${POSITIONAL[@]}"; do
      case "$arg" in
        *.deb)     DEB_PATH="$arg" ;;
        *.tar.zst) SIDECAR_PATH="$arg" ;;
        *)         die "arg has unrecognized suffix (expected .deb or .tar.zst): $arg" ;;
      esac
    done
    [ -n "$DEB_PATH" ]     || die "no .deb in args"
    [ -n "$SIDECAR_PATH" ] || die "no .tar.zst in args"
    ;;
  *)
    die "too many positional args (${#POSITIONAL[@]}); expected 0, 1, or 2"
    ;;
esac

# ---- sanity checks -----------------------------------------------------

heading "Validating bundle inputs"

[ -f "$DEB_PATH" ]     || die "deb not found: $DEB_PATH"
[ -r "$DEB_PATH" ]     || die "deb not readable: $DEB_PATH"
[ -f "$SIDECAR_PATH" ] || die "sidecar not found: $SIDECAR_PATH"
[ -r "$SIDECAR_PATH" ] || die "sidecar not readable: $SIDECAR_PATH"

DEB_BASE="$(basename "$DEB_PATH")"
SIDECAR_BASE="$(basename "$SIDECAR_PATH")"

DEB_STEM="${DEB_BASE%.deb}"
SIDECAR_STEM="${SIDECAR_BASE%.tar.zst}"

# Both filenames must start with the package name prefix.
case "$DEB_STEM" in
  "${PKG_NAME}-"*) ;;
  *) die "deb filename does not start with '${PKG_NAME}-': $DEB_BASE" ;;
esac
case "$SIDECAR_STEM" in
  "${PKG_NAME}-"*) ;;
  *) die "sidecar filename does not start with '${PKG_NAME}-': $SIDECAR_BASE" ;;
esac

# String-equality check on the stems guarantees version+arch match.
if [ "$DEB_STEM" != "$SIDECAR_STEM" ]; then
  err "filename mismatch: .deb and .tar.zst do not refer to the same bundle"
  info "  deb stem:     $DEB_STEM"
  info "  sidecar stem: $SIDECAR_STEM"
  die "refusing to proceed; pass a matched pair"
fi

pass "filenames agree: $DEB_STEM"

# Strip prefix and split off the trailing -<arch>.
REST="${DEB_STEM#${PKG_NAME}-}"
BUNDLE_ARCH="${REST##*-}"
BUNDLE_VERSION="${REST%-*}"

if [ -z "$BUNDLE_ARCH" ] || [ "$BUNDLE_ARCH" = "$REST" ]; then
  die "could not parse <version>-<arch> from filename stem: $DEB_STEM"
fi
if [ -z "$BUNDLE_VERSION" ]; then
  die "could not parse version from filename stem: $DEB_STEM"
fi

info "bundle version: $BUNDLE_VERSION"
info "bundle arch:    $BUNDLE_ARCH"

# Host arch check via dpkg --print-architecture (canonical Debian arch).
if ! command -v dpkg >/dev/null 2>&1; then
  die "dpkg not found in PATH (this script must run on a Debian/Ubuntu host)"
fi
HOST_ARCH="$(dpkg --print-architecture)"
if [ "$HOST_ARCH" != "$BUNDLE_ARCH" ]; then
  err "arch mismatch: this bundle is for ${BUNDLE_ARCH}; this host is ${HOST_ARCH}"
  die "use the *-${HOST_ARCH}.{deb,tar.zst} pair for this host"
fi
pass "host arch matches bundle: $HOST_ARCH"

# Required tools for sidecar extract.
if [ "$SKIP_EXTRACT" -eq 0 ]; then
  command -v tar  >/dev/null 2>&1 || die "tar not found in PATH (needed to extract sidecar)"
  if ! command -v zstd >/dev/null 2>&1 && ! command -v unzstd >/dev/null 2>&1; then
    die "zstd/unzstd not found in PATH (apt install zstd)"
  fi
fi

# Root check — we need to extract under / and run dpkg -i. In dry-run
# mode we let non-root through so operators can preview their args
# without sudo.
if [ "$DRY_RUN" -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
fi

heading "Installing ${PKG_NAME} ${BUNDLE_VERSION} (${BUNDLE_ARCH})"
info "deb:     $DEB_PATH"
info "sidecar: $SIDECAR_PATH"
[ "$DRY_RUN" -eq 1 ]      && info "mode:    DRY-RUN (no changes)"
[ "$SKIP_EXTRACT" -eq 1 ] && info "mode:    --skip-extract (sidecar extract skipped)"

# ---- step 0: legacy-fat-deb transition ---------------------------------
#
# Pre-RFC-0007 .debs (the "fat" format) shipped image tarballs INSIDE
# the .deb at /var/lib/k0s/images/*.tar. dpkg therefore considered
# those paths owned by the package. When a sidecar-format .deb (which
# owns zero tarball paths) is installed *over* a fat .deb, dpkg's
# upgrade behavior removes the "no longer in package" files —
# including any tarballs we just extracted from the sidecar. The new
# postinst's R0 then runs against a half-empty directory and fails.
#
# Detect this transition by asking dpkg which files the currently-
# installed phantomos-k0s-images package owns. If any *.tar paths
# under /var/lib/k0s/images/ are listed, it's a fat-format install —
# remove the package first (keeps the on-disk *.tar files until the
# sidecar extract overwrites them).

heading "Checking for legacy fat-format installation"
if dpkg -s "$PKG_NAME" >/dev/null 2>&1; then
  legacy_count="$(dpkg -L "$PKG_NAME" 2>/dev/null \
                  | grep -cE '^/var/lib/k0s/images/.*\.tar$' || true)"
  if [ "${legacy_count:-0}" -gt 0 ]; then
    warn "found legacy fat-format ${PKG_NAME} owning ${legacy_count} tarball(s)"
    info "  removing it before extract so dpkg won't delete sidecar tarballs"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "  would run: dpkg --remove --force-deps $PKG_NAME"
    else
      if ! dpkg --remove --force-deps "$PKG_NAME" 2>&1; then
        die "failed to remove legacy fat-format $PKG_NAME"
      fi
      pass "legacy package removed (tarballs left on disk; sidecar will overwrite)"
    fi
  else
    info "${PKG_NAME} already installed as sidecar format — clean upgrade"
  fi
else
  info "${PKG_NAME} not yet installed — fresh install"
fi

# ---- step 1: extract sidecar ------------------------------------------

if [ "$SKIP_EXTRACT" -eq 0 ]; then
  heading "Extracting sidecar to /"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would run: tar -I 'zstd -d -T0' -xf $SIDECAR_PATH -C /"
  else
    if ! tar -I 'zstd -d -T0' -xf "$SIDECAR_PATH" -C /; then
      die "sidecar extract failed (tar/zstd pipeline)"
    fi
    # Sanity: at least one *.tar should have landed under TARGET_DIR.
    if ! find "$TARGET_DIR" -maxdepth 1 -name '*.tar' -type f -print -quit \
           | grep -q .; then
      die "sidecar extracted but no *.tar files under $TARGET_DIR (corrupt sidecar?)"
    fi
    EXTRACTED_COUNT="$(find "$TARGET_DIR" -maxdepth 1 -name '*.tar' -type f \
                        2>/dev/null | wc -l | tr -d '[:space:]')"
    pass "sidecar extracted (${EXTRACTED_COUNT} tarball(s) under ${TARGET_DIR})"
  fi
else
  info "skipping sidecar extract (--skip-extract)"
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! find "$TARGET_DIR" -maxdepth 1 -name '*.tar' -type f -print -quit \
           2>/dev/null | grep -q .; then
      warn "no *.tar files under $TARGET_DIR — postinst will fail-fast"
    fi
  fi
fi

# ---- step 2: dpkg -i ---------------------------------------------------

heading "Installing .deb"
if [ "$DRY_RUN" -eq 1 ]; then
  info "would run: dpkg -i $DEB_PATH"
  pass "dry-run complete (no changes made)"
  exit 0
fi

# Run dpkg -i and propagate its exit code so dpkg's own rollback /
# error-reporting semantics are visible to the operator.
set +e
dpkg -i "$DEB_PATH"
DPKG_RC=$?
set -e

if [ "$DPKG_RC" -ne 0 ]; then
  err "dpkg -i failed (exit $DPKG_RC)"
  exit "$DPKG_RC"
fi

heading "Done"
if [ "$SKIP_EXTRACT" -eq 0 ]; then
  pass "installed ${DEB_BASE} + extracted ${EXTRACTED_COUNT:-?} tarballs from ${SIDECAR_BASE}"
else
  pass "installed ${DEB_BASE} (sidecar extract skipped)"
fi
exit 0
