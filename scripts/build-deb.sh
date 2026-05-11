#!/usr/bin/env bash
# build-deb.sh -- produce a phantomos-k0s_<version>_all.deb that installs
# this repo at /opt/Phantom-OS-KubernetesOptions on a target host.
#
# Usage:
#   scripts/build-deb.sh                            # auto-versioned from git
#   VERSION=0.2.0 scripts/build-deb.sh              # explicit version
#   DEB_MAINTAINER="X <x@y>" scripts/build-deb.sh   # override maintainer
#   PKG_NAME=phantomos-k0s scripts/build-deb.sh     # override package name
#
# Requires: dpkg-deb, rsync. No fakeroot/debhelper needed; we use
# `dpkg-deb --root-owner-group` to set root:root on packaged files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PKG_NAME="${PKG_NAME:-phantomos-k0s}"
INSTALL_PREFIX="/opt/Phantom-OS-KubernetesOptions"
ARCH="all"

# ---- prerequisites ------------------------------------------------------

for tool in dpkg-deb rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build-deb.sh: required tool '$tool' not found in PATH" >&2
    echo "  hint: sudo apt install dpkg rsync" >&2
    exit 1
  fi
done

# ---- version derivation -------------------------------------------------

derive_version() {
  if [ -n "${VERSION:-}" ]; then
    printf '%s' "$VERSION"
    return
  fi

  local base date sha
  if [ ! -f "$REPO_ROOT/version.txt" ]; then
    echo "build-deb.sh: version.txt not found at $REPO_ROOT/version.txt" >&2
    echo "  hint: set VERSION=... or create version.txt with a single line like '0.1.0'" >&2
    exit 1
  fi
  base="$(tr -d '[:space:]' < "$REPO_ROOT/version.txt")"
  if [ -z "$base" ]; then
    echo "build-deb.sh: version.txt is empty" >&2
    exit 1
  fi

  if sha=$(git rev-parse --short=7 HEAD 2>/dev/null); then
    date=$(date -u +%Y%m%d)
    # `+` and `.` only — keeps the embedded Debian Version field a
    # "native" version (no debian_revision split), which dpkg/apt
    # version-compare correctly. The output filename is flattened to
    # all hyphens separately below.
    base="${base}+${date}.g${sha}"
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      base="${base}+dirty"
    fi
  fi

  printf '%s' "$base"
}

VERSION="$(derive_version)"
DEB_MAINTAINER="${DEB_MAINTAINER:-Foundation Bot <ops@foundation.bot>}"

# Debian versions allow [A-Za-z0-9.+~-] -- our format is fine, but
# guard against accidentally smuggling in spaces or slashes.
case "$VERSION" in
  *' '*|*/*) echo "build-deb.sh: invalid VERSION '$VERSION'" >&2; exit 1 ;;
esac

# ---- staging ------------------------------------------------------------

DIST_DIR="$REPO_ROOT/dist"
STAGE_DIR="$DIST_DIR/build/${PKG_NAME}_${VERSION}_${ARCH}"
# Filename-only version: flatten `.` and `+` to `-` for a visually
# consistent output name (e.g. 0.0.1+20260507.g19f774a+dirty becomes
# 0-0-1-20260507-g19f774a-dirty). The Debian Version field embedded
# in the package keeps `.` and `+` so it remains a valid native
# version that dpkg/apt can version-compare correctly.
FILENAME_VERSION="${VERSION//./-}"
FILENAME_VERSION="${FILENAME_VERSION//+/-}"
DEB_PATH="$DIST_DIR/${PKG_NAME}-${FILENAME_VERSION}-${ARCH}.deb"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/DEBIAN"
mkdir -p "$STAGE_DIR$INSTALL_PREFIX"

# Copy repo contents into the staging tree, excluding VCS, build
# artifacts, local working drafts, and the packaging/dist scaffolding
# itself.
rsync -a \
  --exclude='.git/' \
  --exclude='.gitignore' \
  --exclude='dist/' \
  --exclude='packaging/' \
  --exclude='/docs/internal/' \
  --exclude='/fix*.sh' \
  --exclude='.claude/' \
  --exclude='.obsidian/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.swp' \
  ./ "$STAGE_DIR$INSTALL_PREFIX/"

# Defensive: ensure shipped scripts are executable.
find "$STAGE_DIR$INSTALL_PREFIX/scripts" \
  -type f \( -name '*.sh' -o -name '*.py' \) \
  -exec chmod 0755 {} + 2>/dev/null || true

# Normalize permissions: 755 on directories, 644 on regular files (the
# `find -exec chmod 0755` above re-marks executables we want to keep
# executable). Matches Debian convention; avoids rsync passing through
# the working tree's 775 group-writable dir mode.
find "$STAGE_DIR$INSTALL_PREFIX" -type d -exec chmod 0755 {} +
find "$STAGE_DIR$INSTALL_PREFIX" -type f ! -perm -u+x -exec chmod 0644 {} +

# ---- embed git repo inside staged tree ---------------------------------
# RFC 0006: the installed tree at /opt/Phantom-OS-KubernetesOptions is a
# real git repo so ArgoCD can clone it via file:///opt/... . Init must
# run AFTER all rsync/install/permission steps so the single commit
# captures the final tree exactly as it'll land on the robot.
echo "==> initializing git repo inside staged tree"
INSTALL_TREE="$STAGE_DIR$INSTALL_PREFIX"
git -C "$INSTALL_TREE" init -q -b main
git -C "$INSTALL_TREE" config user.email "phantomos@foundation.bot"
git -C "$INSTALL_TREE" config user.name "phantomos build"
git -C "$INSTALL_TREE" add -A
git -C "$INSTALL_TREE" commit -q -m "phantomos-k0s ${VERSION}"
git -C "$INSTALL_TREE" gc --aggressive --prune=now -q
PACKED_GIT_SIZE=$(du -sh "$INSTALL_TREE/.git" | awk '{print $1}')
echo "    .git/ size after gc: $PACKED_GIT_SIZE"

# ---- control + maintainer scripts --------------------------------------

INSTALLED_SIZE=$(du -sk "$STAGE_DIR$INSTALL_PREFIX" | awk '{print $1}')

sed \
  -e "s|@VERSION@|$VERSION|g" \
  -e "s|@ARCH@|$ARCH|g" \
  -e "s|@MAINTAINER@|$DEB_MAINTAINER|g" \
  -e "s|@INSTALLED_SIZE@|$INSTALLED_SIZE|g" \
  packaging/deb/control.in > "$STAGE_DIR/DEBIAN/control"

for f in preinst postinst prerm postrm; do
  if [ -f "packaging/deb/$f" ]; then
    install -m 0755 "packaging/deb/$f" "$STAGE_DIR/DEBIAN/$f"
  fi
done

# ---- build --------------------------------------------------------------

mkdir -p "$DIST_DIR"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$DEB_PATH" >/dev/null

echo "built: $DEB_PATH"
echo
dpkg-deb -I "$DEB_PATH" | sed 's/^/  /'
