#!/usr/bin/env bash
# extract-models-to-host.sh — copy the model/policy trees baked into the
# phantom-models / phantom-policies carrier images out onto the host.
#
# WHY: phantomos-api-server (the operator-UI policy picker backend) mounts
# the host's /root/models read-only (hostPath, DirectoryOrCreate) and lists
# it via /policy/list. On a freshly-imaged robot that path is empty. This
# script populates it from the same carrier images the in-cluster stacks use,
# so /policy/list shows the policies without any manual scp.
#
# Mapping (verified against the images):
#   phantom-models  :/models/.          -> <dest>/            (teleop/walking/… dirs)
#   phantom-policies:/models/policies/. -> <dest>/policies/   (encoder/decoder onnx)
# where <dest> defaults to /root/models. The two trees are disjoint, so a
# single robot can extract both without clobber.
#
# Non-destructive: contents are overlaid onto <dest> via `docker cp`; existing
# hand-placed files survive (same-named files are overwritten). <dest> is
# never wiped. Safe to re-run (idempotent).
#
# Idempotency: after a successful extract of <ref> into <dest>, a marker
# file <dest>/.extracted-ref records the ref. A re-run with the SAME ref
# (and no --force) is a true no-op — the docker create/cp/rm is skipped.
# A CHANGED ref re-extracts (overlay, as before). Models are self-versioned
# (the tag changes when the content changes), so an in-place overwrite of a
# flat tree is the whole versioning story — no version dirs / symlinks / GC.
#
# Mechanism: `docker create` an ephemeral container from each ref, `docker cp`
# the subtree out, `docker rm` the container. docker is the only dependency
# (already required by load-image-tars.sh, the script that loads these tars).
#
# Usage:
#   scripts/extract-models-to-host.sh [--dry-run] [--dest DIR] \
#       [--models-ref REF] [--policies-ref REF]
#
# At least one of --models-ref / --policies-ref is required.
#
# Flags:
#   --models-ref REF    image ref whose /models tree is copied to <dest>
#   --policies-ref REF  image ref whose /models/policies tree is copied to
#                       <dest>/policies
#   --dest DIR          host destination root (default: /root/models)
#   --force             ignore the .extracted-ref marker and re-extract
#   --dry-run           print the docker create/cp/rm that WOULD run; no docker
#   -h, --help          this help
#
# Env:
#   DOCKER   docker binary to use (default: docker) — overridable for tests.
#
# Exit code: number of refs that failed to extract (0 = all good).

set -u -o pipefail

DOCKER="${DOCKER:-docker}"
DEST="/root/models"
DRY_RUN=0
FORCE=0
MODELS_REF=""
POLICIES_REF=""

# ---- color/output helpers (match scripts/load-image-tars.sh style) ---------

C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_RESET=$'\033[0m'
[ -t 1 ] || { C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""; }

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

# ---- arg parsing -----------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    --dest)         DEST="${2:-}"; shift 2 ;;
    --models-ref)   MODELS_REF="${2:-}"; shift 2 ;;
    --policies-ref) POLICIES_REF="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             err "unknown flag: $1"; usage; exit 2 ;;
    *)              err "unexpected argument: $1"; usage; exit 2 ;;
  esac
done

if [ -z "$MODELS_REF" ] && [ -z "$POLICIES_REF" ]; then
  err "nothing to do: pass --models-ref and/or --policies-ref"
  usage
  exit 2
fi

# docker is required for a real run (not in --dry-run, which prints only).
if [ "$DRY_RUN" -eq 0 ]; then
  command -v "$DOCKER" >/dev/null 2>&1 \
    || die "docker not found (looked for '$DOCKER'); this script copies image contents via docker"
fi

# ---- extraction ------------------------------------------------------------

FAILURES=0

# extract <ref> <src-in-image> <dest-dir>
#   Copies <src-in-image>/. out of an ephemeral container made from <ref>
#   into <dest-dir>, merging non-destructively. Returns nonzero on failure.
#
#   Idempotency: <dest-dir>/.extracted-ref records the ref last extracted
#   into <dest-dir>. If it already equals <ref> (and --force not given),
#   the docker create/cp/rm is skipped. The marker is written only after a
#   successful copy, so a partial/failed extract never marks the dir clean.
extract() {
  local ref="$1" src="$2" dest="$3" cid
  local marker="$dest/.extracted-ref"

  # No-op fast path: already at this ref. --dry-run honors it too so the
  # plan reflects what a real run would do. --force bypasses it.
  if [ "$FORCE" -eq 0 ] && [ -f "$marker" ] \
     && [ "$(cat "$marker" 2>/dev/null)" = "$ref" ]; then
    pass "already at $ref, skipping ($dest)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "would run: $DOCKER create $ref"
    info "would run: $DOCKER cp <cid>:${src}/. $dest/"
    info "would run: $DOCKER rm <cid>"
    info "would write marker: $marker = $ref"
    return 0
  fi

  if ! cid="$("$DOCKER" create "$ref" 2>/dev/null)" || [ -z "$cid" ]; then
    err "could not create a container from $ref"
    return 1
  fi

  local rc=0
  mkdir -p "$dest"
  if "$DOCKER" cp "${cid}:${src}/." "$dest/"; then
    pass "$ref ${src} -> $dest/"
    # Record the ref only on success so a failed copy doesn't poison the
    # idempotency check on the next run.
    printf '%s\n' "$ref" > "$marker" \
      || warn "extracted $ref but could not write marker $marker (re-runs will re-extract)"
  else
    err "$ref has no $src (or copy failed); nothing extracted"
    rc=1
  fi

  "$DOCKER" rm "$cid" >/dev/null 2>&1 || warn "could not remove temp container $cid"
  return "$rc"
}

heading "Extracting model/policy trees to $DEST"
[ "$DRY_RUN" -eq 1 ] && info "mode: DRY-RUN (no docker actions)"

if [ -n "$MODELS_REF" ]; then
  heading "phantom-models: $MODELS_REF"
  extract "$MODELS_REF" "/models" "$DEST" || FAILURES=$((FAILURES + 1))
fi

if [ -n "$POLICIES_REF" ]; then
  heading "phantom-policies: $POLICIES_REF"
  extract "$POLICIES_REF" "/models/policies" "$DEST/policies" || FAILURES=$((FAILURES + 1))
fi

heading "Done"
if [ "$FAILURES" -eq 0 ]; then
  pass "all requested trees extracted to $DEST"
else
  err "$FAILURES extraction(s) failed"
fi

exit "$FAILURES"
