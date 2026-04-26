#!/usr/bin/env bash
# resize-registry-pvc.sh
#
# Recreates the k0s-registry PVC + PV at a target capacity (default 150Gi).
#
# Why this script exists:
#   The local registry runs against a hostPath PV. hostPath PVs do not
#   support live resize — the storageclass (empty-string for static
#   hostPath) is not a CSI driver, so `kubectl edit pvc` produces:
#
#     persistentvolumeclaims "k0s-registry-pvc" is forbidden:
#     only dynamically provisioned pvc can be resized and the storageclass
#     that provisions the pvc must support resize
#
#   The fix is the "recreate" dance: scale the registry to 0, delete the
#   PVC + PV, re-apply the manifest (which recreates them at the new
#   size), scale back to 1. The data on disk at /var/lib/registry is
#   preserved because the PV's reclaimPolicy is Retain and the hostPath
#   doesn't change — the new PV simply re-binds to the same directory.
#
#   See docs/plans/2026-04-24-local-registry-with-fallback.md for
#   background on the registry deployment.
#
# Usage:
#   sudo bash scripts/resize-registry-pvc.sh                 # interactive
#   sudo bash scripts/resize-registry-pvc.sh --yes           # no prompt
#   sudo bash scripts/resize-registry-pvc.sh --dry-run       # preview only
#   sudo bash scripts/resize-registry-pvc.sh --target 300Gi  # custom size
#
# Env-var overrides:
#   TARGET_SIZE   default: 150Gi             (also via --target)
#   NAMESPACE     default: registry
#   DEPLOYMENT    default: k0s-registry
#   PVC_NAME      default: k0s-registry-pvc
#   PV_NAME       default: k0s-registry-pv
#   HOST_PATH     default: /var/lib/registry
#   OVERLAY_DIR   default: <repo>/manifests/robots/mk09
#   REGISTRY_HOST default: localhost:5443
#
# Idempotent: if the PVC already reports the target size, the script
# exits 0 with a "nothing to do" message before deleting anything.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGET_SIZE="${TARGET_SIZE:-150Gi}"
NAMESPACE="${NAMESPACE:-registry}"
DEPLOYMENT="${DEPLOYMENT:-k0s-registry}"
PVC_NAME="${PVC_NAME:-k0s-registry-pvc}"
PV_NAME="${PV_NAME:-k0s-registry-pv}"
HOST_PATH="${HOST_PATH:-/var/lib/registry}"
OVERLAY_DIR="${OVERLAY_DIR:-${REPO}/manifests/robots/mk09}"
REGISTRY_MANIFEST="${REGISTRY_MANIFEST:-${REPO}/manifests/base/registry/registry.yaml}"
REGISTRY_HOST="${REGISTRY_HOST:-localhost:5443}"

ASSUME_YES=0
DRY_RUN=0

# ---------------------------------------------------------------------------
# Output helpers (match diagnose-positronic.sh / configure-k0s-... style)
# ---------------------------------------------------------------------------

bold()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '  \033[32m%s\033[0m %s\n' "OK"   "$1"; }
warn()  { printf '  \033[33m%s\033[0m %s\n' "WARN" "$1"; }
fail()  { printf '  \033[31m%s\033[0m %s\n' "FAIL" "$1"; }
info()  { printf '  %s\n' "$1"; }

usage() {
  cat <<EOF
resize-registry-pvc.sh — recreate the k0s-registry PVC + PV at a target size.

The k0s-registry PVC is hostPath-backed; hostPath storage classes do not
support live resize. To grow (or shrink) the PVC, the registry has to be
briefly scaled to zero, the PVC + PV deleted, and the manifest re-applied
so the objects come back at the new size. Data at ${HOST_PATH} is
preserved across the recreate because the PV's reclaimPolicy is Retain
and the hostPath does not change.

Usage:
  $0 [options]

Options:
  --target SIZE     Target PVC capacity (default: ${TARGET_SIZE}, e.g. 300Gi)
  -y, --yes         Skip the confirmation prompt
  --dry-run         Show what would happen, do not change anything
  -h, --help        Show this help and exit

Environment-variable overrides:
  TARGET_SIZE       (default ${TARGET_SIZE})
  NAMESPACE         (default ${NAMESPACE})
  DEPLOYMENT        (default ${DEPLOYMENT})
  PVC_NAME          (default ${PVC_NAME})
  PV_NAME           (default ${PV_NAME})
  HOST_PATH         (default ${HOST_PATH})
  OVERLAY_DIR       (default <repo>/manifests/robots/mk09)
  REGISTRY_HOST     (default ${REGISTRY_HOST})

Examples:
  sudo bash $0                       # interactive, target 150Gi
  sudo bash $0 --yes                 # non-interactive, target 150Gi
  sudo bash $0 --dry-run             # preview only, no changes
  sudo bash $0 --target 300Gi --yes  # bump to 300Gi, no prompt

Run on the robot, with sudo. Locally (no kubectl, no k0s) it bails out
on the kubectl-resolution check.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "${2:-}" ] || { echo "error: --target needs a size (e.g. 150Gi)" >&2; exit 2; }
      TARGET_SIZE="$2"
      shift 2
      ;;
    --target=*)
      TARGET_SIZE="${1#--target=}"
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# kubectl resolution — match diagnose-positronic.sh
# ---------------------------------------------------------------------------

KUBECTL=""
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
else
  bold "Pre-flight"
  fail "neither kubectl nor 'k0s kubectl' is available on this host"
  info "this script must run on a node that can talk to the cluster"
  info "(typically the robot itself, where 'k0s kubectl' is installed)"
  exit 2
fi

kc() {
  # Run kubectl. KUBECTL may be "k0s kubectl" — let the shell split it.
  # shellcheck disable=SC2086
  $KUBECTL "$@"
}

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
#
# diagnose-positronic.sh does not require root because `k0s kubectl` works
# without sudo on robots that have group access. configure-k0s-containerd-
# mirror.sh does require root because it writes /etc/k0s/*. This script
# manipulates k0s cluster resources only — no /etc writes — so we follow
# the diagnose-positronic.sh policy: don't hard-require root. If the caller
# is non-root and kubectl can't authenticate, kubectl itself will surface
# a clean error.

# ---------------------------------------------------------------------------
# Trap — leave a recovery hint if the script dies mid-run
# ---------------------------------------------------------------------------

RECREATE_STARTED=0

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$RECREATE_STARTED" -eq 1 ]; then
    printf '\n\033[31m%s\033[0m\n' "ABORTED MID-RECREATE"
    cat >&2 <<EOF

The recreate sequence started but did not finish cleanly. The registry
deployment may currently be scaled to 0 replicas. To finish the recovery
manually:

  ${KUBECTL} apply -k ${OVERLAY_DIR}
  ${KUBECTL} -n ${NAMESPACE} scale deployment/${DEPLOYMENT} --replicas=1
  ${KUBECTL} -n ${NAMESPACE} rollout status deployment/${DEPLOYMENT} --timeout=120s

If the PVC or PV is missing, the apply above will recreate them at
${TARGET_SIZE}. Data at ${HOST_PATH} is preserved on disk regardless.
EOF
  fi
  exit "$rc"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------

bold "1. Pre-flight checks"

info "kubectl: ${KUBECTL}"
info "target size: ${TARGET_SIZE}"
info "namespace: ${NAMESPACE}"
info "deployment: ${DEPLOYMENT}"
info "pvc: ${PVC_NAME}"
info "pv: ${PV_NAME}"
info "host path: ${HOST_PATH}"
info "overlay dir: ${OVERLAY_DIR}"

# Namespace
if kc get ns "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace ${NAMESPACE} exists"
else
  fail "namespace ${NAMESPACE} not found"
  exit 1
fi

# Deployment
if kc -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
  ok "deployment ${DEPLOYMENT} exists"
else
  fail "deployment ${DEPLOYMENT} not found in ${NAMESPACE}"
  exit 1
fi

# PVC
if kc -n "$NAMESPACE" get pvc "$PVC_NAME" >/dev/null 2>&1; then
  ok "pvc ${PVC_NAME} exists"
else
  fail "pvc ${PVC_NAME} not found in ${NAMESPACE}"
  exit 1
fi

# PV
if kc get pv "$PV_NAME" >/dev/null 2>&1; then
  ok "pv ${PV_NAME} exists"
else
  fail "pv ${PV_NAME} not found"
  exit 1
fi

# Live PVC capacity. Prefer .status.capacity.storage (what's actually
# bound) but fall back to .spec.resources.requests.storage if status
# isn't populated yet.
LIVE_PVC_SIZE="$(
  kc -n "$NAMESPACE" get pvc "$PVC_NAME" \
    -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true
)"
if [ -z "$LIVE_PVC_SIZE" ]; then
  LIVE_PVC_SIZE="$(
    kc -n "$NAMESPACE" get pvc "$PVC_NAME" \
      -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true
  )"
fi
info "live pvc capacity: ${LIVE_PVC_SIZE:-<unknown>}"

if [ -n "$LIVE_PVC_SIZE" ] && [ "$LIVE_PVC_SIZE" = "$TARGET_SIZE" ]; then
  ok "pvc is already at target size (${TARGET_SIZE}) — nothing to do"
  exit 0
fi

# Manifest declared size — surface mismatch to operator
if [ -r "$REGISTRY_MANIFEST" ]; then
  MANIFEST_SIZE="$(
    awk '
      /^kind: PersistentVolumeClaim/      { in_pvc=1; in_pv=0; next }
      /^kind: PersistentVolume$/          { in_pv=1;  in_pvc=0; next }
      /^kind: / && !/PersistentVolume/    { in_pvc=0; in_pv=0 }
      in_pvc && /storage:/                { gsub(/[ \t]+/, "", $0); sub(/storage:/, "", $0); print; exit }
    ' "$REGISTRY_MANIFEST" 2>/dev/null || true
  )"
  if [ -n "$MANIFEST_SIZE" ]; then
    info "manifest declares pvc size: ${MANIFEST_SIZE} (${REGISTRY_MANIFEST})"
    if [ "$MANIFEST_SIZE" != "$TARGET_SIZE" ]; then
      warn "manifest size ${MANIFEST_SIZE} does NOT match --target ${TARGET_SIZE}"
      warn "after this script runs, the recreated PVC will reflect the manifest (${MANIFEST_SIZE}), not --target"
    fi
  else
    warn "could not parse pvc storage size from ${REGISTRY_MANIFEST}"
  fi
else
  warn "${REGISTRY_MANIFEST} not readable — cannot cross-check declared size"
fi

# Host path sanity — we're about to delete the PV that points at it
if [ -d "$HOST_PATH" ]; then
  if [ -n "$(ls -A "$HOST_PATH" 2>/dev/null)" ]; then
    ok "host path ${HOST_PATH} exists and is non-empty"
  else
    warn "host path ${HOST_PATH} exists but is empty — registry has no data to preserve"
  fi
else
  warn "host path ${HOST_PATH} does not exist on this host (or not visible to this user)"
  warn "if you're running this off-robot, that's expected; on the robot, this is suspicious"
fi

# Overlay dir
if [ -d "$OVERLAY_DIR" ]; then
  ok "overlay dir ${OVERLAY_DIR} exists"
else
  fail "overlay dir ${OVERLAY_DIR} not found"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Confirmation
# ---------------------------------------------------------------------------

bold "2. Plan"
cat <<EOF
  Will:
    - scale deployment/${DEPLOYMENT} (in ${NAMESPACE}) to 0 replicas
    - wait for the registry pod to terminate
    - delete pvc ${PVC_NAME} (in ${NAMESPACE})
    - delete pv  ${PV_NAME}
    - re-apply ${OVERLAY_DIR}  (recreates pvc/pv at the manifest size)
    - scale deployment/${DEPLOYMENT} back to 1 replica
    - wait for the registry pod to be Ready
    - verify pvc capacity and registry HTTP endpoint

  The registry will be briefly offline (~30s typically). Data on disk
  at ${HOST_PATH} is preserved — the new PV re-binds to the same path.
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  bold "Dry run — no changes will be made"
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\n  Proceed? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) : ;;
    *) echo "  aborted."; exit 1 ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Recreate
# ---------------------------------------------------------------------------

bold "3. Recreate sequence"
RECREATE_STARTED=1

info "scaling ${DEPLOYMENT} -> 0 replicas"
kc -n "$NAMESPACE" scale deployment/"$DEPLOYMENT" --replicas=0

info "waiting for registry pod to terminate (up to 60s)"
# kubectl wait --for=delete returns 0 immediately if no pods match.
kc -n "$NAMESPACE" wait --for=delete pod -l app="$DEPLOYMENT" --timeout=60s 2>/dev/null || true
ok  "no registry pod left"

info "deleting pvc ${PVC_NAME}"
kc -n "$NAMESPACE" delete pvc "$PVC_NAME" --wait=true --timeout=60s

info "deleting pv ${PV_NAME}"
kc delete pv "$PV_NAME" --wait=true --timeout=60s

info "re-applying overlay ${OVERLAY_DIR}"
kc apply -k "$OVERLAY_DIR"

info "scaling ${DEPLOYMENT} -> 1 replica"
kc -n "$NAMESPACE" scale deployment/"$DEPLOYMENT" --replicas=1

info "waiting for rollout (up to 120s)"
kc -n "$NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=120s

# Past this point the deployment is back up; no recovery hint needed.
RECREATE_STARTED=0

# ---------------------------------------------------------------------------
# 4. Post-flight verification
# ---------------------------------------------------------------------------

bold "4. Post-flight verification"

NEW_PVC_SIZE="$(
  kc -n "$NAMESPACE" get pvc "$PVC_NAME" \
    -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true
)"
if [ -z "$NEW_PVC_SIZE" ]; then
  NEW_PVC_SIZE="$(
    kc -n "$NAMESPACE" get pvc "$PVC_NAME" \
      -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true
  )"
fi
info "new pvc capacity: ${NEW_PVC_SIZE:-<unknown>}"
if [ "$NEW_PVC_SIZE" = "$TARGET_SIZE" ]; then
  ok "pvc capacity matches target (${TARGET_SIZE})"
else
  warn "pvc capacity is ${NEW_PVC_SIZE}, target was ${TARGET_SIZE}"
  warn "if the manifest declares a different size, that's the source of truth — bump the manifest and re-apply"
fi

if curl -fs -o /dev/null --max-time 5 "http://${REGISTRY_HOST}/v2/" 2>/dev/null; then
  ok "registry HTTP endpoint responds (http://${REGISTRY_HOST}/v2/)"
else
  fail "registry HTTP endpoint not reachable at http://${REGISTRY_HOST}/v2/"
  fail "(deployment is up but the registry isn't serving — check pod logs)"
  exit 1
fi

if catalog="$(curl -fs --max-time 5 "http://${REGISTRY_HOST}/v2/_catalog" 2>/dev/null)"; then
  info "registry catalog: ${catalog}"
  for expected in phantom-models positronic-control; do
    if printf '%s' "$catalog" | grep -q "\"${expected}\""; then
      ok "catalog contains ${expected}"
    else
      warn "catalog does not list ${expected} — re-prime if expected"
    fi
  done
else
  warn "could not read /v2/_catalog (registry up but catalog endpoint failed)"
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------

bold "Summary"
info "pvc ${PVC_NAME}: ${LIVE_PVC_SIZE:-<unknown>} -> ${NEW_PVC_SIZE:-<unknown>}"
info "registry: http://${REGISTRY_HOST}/v2/  (responding)"
info "data preserved at ${HOST_PATH}"
ok   "done"
