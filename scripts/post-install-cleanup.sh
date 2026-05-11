#!/usr/bin/env bash
# post-install-cleanup.sh — free disk space by removing the bundled
# image tarballs that are now redundant in containerd's local store.
#
# Run AFTER the cluster is healthy. The .deb-installed image bundle
# leaves ~15-18 GB of *.tar files under /var/lib/k0s/images/. Once
# containerd has imported them (postinst's R2 step), the tarballs are
# dead weight — the layers live in containerd's content store.
#
# This script verifies every bundle-manifest tarball corresponds to an
# image in containerd before deleting. If anything's missing, it
# refuses to clean up so the operator can re-import.
#
# Usage:
#   sudo bash scripts/post-install-cleanup.sh           # interactive (verify + ask)
#   sudo bash scripts/post-install-cleanup.sh --yes     # non-interactive
#   sudo bash scripts/post-install-cleanup.sh --dry-run # show what would happen
#   sudo bash scripts/post-install-cleanup.sh --force   # skip verification
#
# Safe to re-run. After cleanup the bundle manifest YAML stays in
# /var/lib/k0s/images/ — it's the historical record of what was bundled.
# To restore the tarballs: re-run install-image-bundle.sh.

set -u

YES=0
DRY_RUN=0
FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y)    YES=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)           echo "error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "error: must run as root (try: sudo bash $0)" >&2
  exit 2
fi

# Pretty-print helpers (match install-image-bundle.sh / teardown.sh).
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi
heading() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }
info()    { printf '  %s\n' "$1"; }
pass()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail()    { printf '  %s✗%s %s\n' "$C_RED"   "$C_RESET" "$1"; }
die()     { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit "${2:-1}"; }

IMAGES_DIR=/var/lib/k0s/images
BUNDLE_MANIFEST=$IMAGES_DIR/.phantomos-image-bundle.yaml

heading "post-install cleanup"
info "removes redundant image tarballs from $IMAGES_DIR after containerd"
info "has imported them. typical savings: 15-18 GB on a full-bundle install."
echo

# ---- 1. preflight ----------------------------------------------------------

if [ ! -d "$IMAGES_DIR" ]; then
  die "$IMAGES_DIR does not exist — nothing to clean"
fi

n_tar=$(find "$IMAGES_DIR" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)
if [ "$n_tar" -eq 0 ]; then
  info "no tarballs under $IMAGES_DIR — already cleaned up"
  exit 0
fi

bytes_before=$(du -sb "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')
hr_before=$(du -sh "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')
info "tarballs to remove:  $n_tar"
info "current size:        $hr_before"
echo

# ---- 2. verify (unless --force) -------------------------------------------

if [ "$FORCE" -eq 1 ]; then
  warn "--force passed; skipping containerd verification"
else
  heading "verifying every bundle tarball is imported into containerd"

  if [ ! -r "$BUNDLE_MANIFEST" ]; then
    warn "$BUNDLE_MANIFEST not present — fallback: assume any tarball with"
    warn "  a matching ref in 'k0s ctr images list' is safe to remove. This"
    warn "  is less strict than the manifest-driven check; if you want the"
    warn "  full safety net, re-install the image .deb first."
  fi

  if ! command -v k0s >/dev/null 2>&1; then
    die "k0s not on PATH — can't verify containerd state. re-run with --force to skip verification."
  fi

  if ! systemctl is-active k0scontroller >/dev/null 2>&1; then
    warn "k0scontroller is not active — containerd is offline."
    warn "  Either start k0scontroller before cleanup, OR run with --force"
    warn "  if you've verified state by other means."
    die "aborted (k0s offline)"
  fi

  # Build the set of refs containerd currently holds.
  containerd_refs="$(k0s ctr -n k8s.io images list -q 2>/dev/null \
                       | sort -u || true)"
  if [ -z "$containerd_refs" ]; then
    die "containerd reports zero images — nothing has been imported. Refusing to clean."
  fi

  # Build the list of (tarball-filename, expected-ref) pairs from the
  # bundle manifest when present; fall back to inspecting each tarball
  # individually when not.
  missing=0
  if [ -r "$BUNDLE_MANIFEST" ]; then
    # Each `tarball: <name>` line in the bundle manifest names a file
    # in $IMAGES_DIR. Each `ref: <name>` immediately above (or below,
    # depending on YAML ordering) names what containerd should hold.
    while IFS=$'\t' read -r ref tarball; do
      [ -z "$ref" ] && continue
      tar_path="$IMAGES_DIR/$tarball"
      if [ ! -f "$tar_path" ]; then
        # Tarball already gone — that's fine, just nothing to delete.
        continue
      fi
      # Containerd shows refs as `docker.io/<repo>:<tag>` or full path.
      # Match the ref against the listing.
      if printf '%s\n' "$containerd_refs" | grep -qE "(^|/)$(printf '%s' "$ref" | sed 's|[][().+*?^$/\\]|\\&|g')$"; then
        pass "$tarball  (ref $ref in containerd)"
      else
        fail "$tarball  (ref $ref NOT in containerd)"
        missing=$((missing + 1))
      fi
    done < <(python3 - "$BUNDLE_MANIFEST" 2>/dev/null <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f) or {}
for entry in cfg.get('bundle', []) or []:
    ref = entry.get('ref') or ''
    tar = entry.get('tarball') or ''
    if ref and tar:
        print(f"{ref}\t{tar}")
PY
)
  else
    # No manifest — inspect each tarball directly via its embedded
    # manifest.json. Slower but doesn't require the sidecar.
    for tar_path in "$IMAGES_DIR"/*.tar; do
      [ -e "$tar_path" ] || continue
      repotags=$(tar -xOf "$tar_path" manifest.json 2>/dev/null \
                   | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d:
        for t in (m.get("RepoTags") or []):
            print(t)
except Exception:
    pass
' 2>/dev/null | head -1)
      if [ -z "$repotags" ]; then
        warn "$(basename "$tar_path")  (could not read RepoTags)"
        continue
      fi
      if printf '%s\n' "$containerd_refs" | grep -qF "$repotags"; then
        pass "$(basename "$tar_path")  (ref $repotags in containerd)"
      else
        fail "$(basename "$tar_path")  (ref $repotags NOT in containerd)"
        missing=$((missing + 1))
      fi
    done
  fi

  if [ "$missing" -gt 0 ]; then
    echo
    die "$missing tarball(s) not represented in containerd — refusing to clean up. Either re-run install-image-bundle.sh to re-import, OR pass --force to delete anyway."
  fi
  echo
  pass "all tarballs verified in containerd"
fi

# ---- 3. confirm + delete ---------------------------------------------------

echo
if [ "$YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  printf '  delete %d tarball(s) (%s)? [y/N] ' "$n_tar" "$hr_before"
  IFS= read -r reply
  case "${reply:-n}" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

heading "removing tarballs"
if [ "$DRY_RUN" -eq 1 ]; then
  find "$IMAGES_DIR" -maxdepth 1 -name '*.tar' -print | sed 's/^/  DRY-RUN  rm /'
else
  find "$IMAGES_DIR" -maxdepth 1 -name '*.tar' -delete
fi
echo

heading "summary"
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run; no changes made)"
else
  bytes_after=$(du -sb "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')
  freed=$((bytes_before - bytes_after))
  hr_after=$(du -sh "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')
  hr_freed=$(numfmt --to=iec --suffix=B --format='%.1f' "$freed" 2>/dev/null || echo "$freed bytes")
  pass "freed $hr_freed"
  info "before:  $hr_before"
  info "after:   $hr_after"
  info "(bundle manifest preserved at $BUNDLE_MANIFEST)"
fi
echo
