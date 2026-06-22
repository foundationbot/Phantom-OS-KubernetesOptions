#!/usr/bin/env bash
# load-image-tars.sh — load locally-built image tarballs into Docker and
# push their localhost:5443/* tags into the in-cluster registry.
#
# This is the scripted form of operations.md §3.13 step 3: an operator who
# has `docker save`d a prebuilt carrier image (e.g. phantom-models /
# phantom-policies) to a tarball on one robot can load it here and push it
# into the local registry pod so other robots' manifests can pull it.
#
# Pure registry operation — it has NO host-config knowledge and does not
# edit host-config.yaml; the --load-image-tars bootstrap phase wires the
# resulting tag in. Usable off-robot for ad-hoc loads.
#
# Usage:
#   scripts/load-image-tars.sh [--dry-run] <tarball> [<tarball> ...]
#
# Per tarball:
#   1. Validate the path is a readable file.
#   2. Decompress by extension and `docker load`:
#        .tar           → docker load -i <f>
#        .tar.gz / .tgz → docker load -i <f>   (docker handles gzip natively)
#        .tar.zst       → zstd -dc <f> | docker load
#   3. Capture the loaded ref(s) from `docker load` output
#      ("Loaded image: <ref>"). An older "Loaded image ID:" line carries no
#      tag and is warned about (nothing to push).
#   4. Guard: a loaded ref that is NOT localhost:5443/* is warned and its
#      push skipped — the registry pod only serves that prefix.
#   5. `docker push <ref>` for each localhost:5443/* ref.
#   6. Print each pushed ref to stdout, one per line, prefixed "PUSHED "
#      (e.g. "PUSHED localhost:5443/phantom-models:2026-06-08") so a caller
#      can grep/parse it. All other output goes to stderr.
#
# Flags:
#   --dry-run    validate file existence and print the docker load / push
#                that WOULD run, without invoking docker, the registry, or
#                zstd. Where the ref is not knowable without loading, say so.
#   -h, --help   this help
#
# Preconditions: requires `docker` in PATH; `zstd`/`unzstd` only when a .zst
# input is given. Before any push, the registry at localhost:5443 must be
# reachable (http://localhost:5443/v2/); the script dies clearly if not.
#
# Idempotency: safe to re-run. Loading the same tarball overwrites identical
# layers; pushing an already-present ref is a no-op. Exit code = number of
# failures (0 = all good); a bad tarball path fails that item but the script
# continues to the next.

set -u -o pipefail

REGISTRY_HOST="${REGISTRY_HOST:-localhost:5443}"
REGISTRY_PREFIX="${REGISTRY_HOST}/"
REGISTRY_V2_URL="http://${REGISTRY_HOST}/v2/"

# ---- color/output helpers (match scripts/install-image-bundle.sh style) ----

C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_RED=$'\033[31m'
C_RESET=$'\033[0m'

# C_CYAN is kept for parity with install-image-bundle.sh's helper block.
# shellcheck disable=SC2034
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

# ---- arg parsing -----------------------------------------------------------

DRY_RUN=0
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)        err "unknown flag: $1"; usage; exit 2 ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done

if [ "${#POSITIONAL[@]}" -eq 0 ]; then
  err "no tarballs given"
  usage
  exit 2
fi

# ---- preconditions ---------------------------------------------------------

# `docker` is required even in --dry-run-adjacent reasoning, but in --dry-run
# we only print what would run, so don't hard-require the daemon there. We
# still require the binary's presence for a real run.
if [ "$DRY_RUN" -eq 0 ]; then
  command -v docker >/dev/null 2>&1 \
    || die "docker not found in PATH (this script loads/pushes images via docker)"
fi

# Does any input need zstd? Require it up front (real runs only).
needs_zstd=0
for f in "${POSITIONAL[@]}"; do
  case "$f" in
    *.tar.zst) needs_zstd=1 ;;
  esac
done
if [ "$needs_zstd" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  if ! command -v zstd >/dev/null 2>&1 && ! command -v unzstd >/dev/null 2>&1; then
    die "zstd/unzstd not found in PATH but a .tar.zst input was given (apt install zstd)"
  fi
fi

# Registry reachability — required before any push. Skipped in --dry-run.
if [ "$DRY_RUN" -eq 0 ]; then
  command -v curl >/dev/null 2>&1 \
    || die "curl not found in PATH (needed to check the registry is reachable)"
  if ! curl -fs -o /dev/null --max-time 5 "$REGISTRY_V2_URL"; then
    die "registry not reachable at ${REGISTRY_HOST} (${REGISTRY_V2_URL}); is the k0s-registry pod up?"
  fi
fi

# ---- per-tarball processing ------------------------------------------------

FAILURES=0

heading "Loading ${#POSITIONAL[@]} image tarball(s)"
[ "$DRY_RUN" -eq 1 ] && info "mode: DRY-RUN (no docker/registry/zstd actions)"
info "registry: ${REGISTRY_HOST}"

# load_refs <tarball> — run the appropriate docker-load pipeline and echo
# the loaded refs (one per line) to STDOUT of this function. Returns nonzero
# on a load failure. Status/log lines go to stderr.
load_refs() {
  local f="$1" out
  case "$f" in
    *.tar.zst)
      if ! out="$(zstd -dc -- "$f" | docker load 2>&1)"; then
        err "docker load failed for $f"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        return 1
      fi
      ;;
    *.tar|*.tar.gz|*.tgz)
      if ! out="$(docker load -i "$f" 2>&1)"; then
        err "docker load failed for $f"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        return 1
      fi
      ;;
    *)
      err "unrecognized extension (expected .tar, .tar.gz, .tgz, or .tar.zst): $f"
      return 1
      ;;
  esac

  # "Loaded image: <ref>" lines carry a tag we can push.
  printf '%s\n' "$out" \
    | sed -n 's/^Loaded image: //p'

  # "Loaded image ID: sha256:..." carries no tag — warn, nothing to push.
  if printf '%s\n' "$out" | grep -q '^Loaded image ID:'; then
    warn "$f loaded an untagged image (no 'Loaded image: <ref>'); nothing to push"
  fi
}

for f in "${POSITIONAL[@]}"; do
  heading "$(basename "$f")"

  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    err "not a readable file: $f"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  case "$f" in
    *.tar|*.tar.gz|*.tgz|*.tar.zst) ;;
    *)
      err "unrecognized extension (expected .tar, .tar.gz, .tgz, or .tar.zst): $f"
      FAILURES=$((FAILURES + 1))
      continue
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    case "$f" in
      *.tar.zst) info "would run: zstd -dc -- '$f' | docker load" ;;
      *)         info "would run: docker load -i '$f'" ;;
    esac
    hint "ref(s) not knowable without loading; would push each localhost:5443/* ref"
    hint "would skip pushing any ref not under ${REGISTRY_PREFIX}"
    continue
  fi

  # Real run: load, then push each localhost:5443/* ref.
  refs=()
  if ! mapfile -t refs < <(load_refs "$f"); then
    FAILURES=$((FAILURES + 1))
    continue
  fi

  if [ "${#refs[@]}" -eq 0 ]; then
    warn "$f produced no taggable refs; nothing to push"
    continue
  fi

  item_failed=0
  for ref in "${refs[@]}"; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "${REGISTRY_PREFIX}"*)
        info "pushing $ref"
        if docker push "$ref" >&2; then
          pass "pushed $ref"
          # Parseable line on stdout for callers to grep.
          printf 'PUSHED %s\n' "$ref"
        else
          err "docker push failed for $ref"
          item_failed=1
        fi
        ;;
      *)
        warn "skipping push of $ref (not under ${REGISTRY_PREFIX}; registry only serves that prefix)"
        ;;
    esac
  done

  [ "$item_failed" -eq 1 ] && FAILURES=$((FAILURES + 1))
done

# ---- summary ---------------------------------------------------------------

heading "Done"
if [ "$FAILURES" -eq 0 ]; then
  pass "all inputs processed without failures"
else
  err "$FAILURES input(s) failed"
fi

exit "$FAILURES"
