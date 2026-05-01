#!/usr/bin/env bash
# reset-deployment.sh — tear down and rebuild every stateful resource
# binding while preserving on-disk data.
#
# When to use this:
#   - Cross-bound PVs (the wrong PVC is mounted on the wrong PV)
#   - Multiple PVCs in Lost state at once
#   - ArgoCD drift that won't reconcile because of stale claimRefs
#   - "Just give me a clean slate" recovery
#
# Why it's safe: every PV in this stack uses reclaimPolicy: Retain, so
# deleting the PV does NOT touch the underlying hostPath. The data on
# /var/lib/k0s-data/{mongodb,redis,postgres}, /root/recordings, and
# /var/lib/registry survives the recreate.
#
# Steps (executed in order):
#   1. Suspend ArgoCD selfHeal+prune on the phantomos-mk09 Application
#   2. Scale all stateful consumers to 0
#         argus/mongodb (sts), argus/redis (sts), nimbus/postgres (sts),
#         nimbus/eg-server (deploy), nimbus/eg-jobs (deploy),
#         registry/k0s-registry (deploy)
#   3. Delete the corresponding PVCs:
#         data-{mongodb,redis,postgres}-0, recordings-pvc, k0s-registry-pvc
#   4. Delete all PVs:
#         {mongodb,redis,postgres,recordings,k0s-registry}-pv
#   5. kubectl apply -k <overlay> to recreate everything from manifest
#   6. Scale registry back up FIRST (so its PVC claims its PV before any
#      race window), then mongodb/redis/postgres, then eg-server/eg-jobs
#   7. Re-enable ArgoCD selfHeal+prune; force a hard refresh
#   8. Print a verification report
#
# Usage:
#   sudo bash scripts/reset-deployment.sh           # interactive confirm
#   sudo bash scripts/reset-deployment.sh --yes     # non-interactive
#   sudo bash scripts/reset-deployment.sh --dry-run # preview only
#   sudo bash scripts/reset-deployment.sh --skip-argocd  # don't touch the Application
#
# Companions:
#   scripts/rebind-stuck-pvc.sh — per-PVC recovery (smaller scope)
#   scripts/resize-registry-pvc.sh — registry PVC resize only

set -u -o pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

# Resolve robot identity via the shared helper. Falls through to mk09
# only if everything else fails AND the operator has explicitly opted
# in via ROBOT=mk09 — otherwise it's a hard error.
if [ -z "${OVERLAY:-}" ] || [ -z "${ARGOCD_APP:-}" ]; then
  REPO_ROOT="$REPO"
  # shellcheck source=lib/robot-id.sh
  . "$(dirname "$0")/lib/robot-id.sh"
  if _robot="$(resolve_robot "${ROBOT:-}")"; then
    OVERLAY="${OVERLAY:-${REPO}/manifests/robots/${_robot}}"
    ARGOCD_APP="${ARGOCD_APP:-phantomos-${_robot}}"
  else
    echo "error: could not resolve robot — set OVERLAY and ARGOCD_APP, or ROBOT" >&2
    exit 2
  fi
fi

# kubectl resolution: prefer standalone kubectl, fall back to `k0s kubectl`.
KUBECTL=""
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
fi

ASSUME_YES=0
DRY_RUN=0
SKIP_ARGOCD=0

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --skip-argocd) SKIP_ARGOCD=1; shift ;;
    *) echo "error: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$KUBECTL" ]; then
  fail "neither kubectl nor 'k0s kubectl' is available on this host"
  exit 2
fi

run() {
  printf '    $ %s\n' "$*"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  eval "$@"
}

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  printf '\n%s [y/N]: ' "$prompt"
  read -r ans </dev/tty || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- 0. Plan summary ------------------------------------------------------
bold "reset-deployment — full PV/PVC rebuild for every stateful resource"
echo "  kubectl: $KUBECTL"
echo "  repo:    $REPO"
echo "  overlay: $OVERLAY"
echo "  argocd:  ${ARGOCD_NS}/${ARGOCD_APP} (skip=$SKIP_ARGOCD)"
[ "$DRY_RUN" = 1 ]    && echo "  --dry-run: ON (no changes will be made)"
[ "$ASSUME_YES" = 1 ] && echo "  --yes: ON (no confirmation prompts)"

cat <<EOF

  Will scale to 0:  argus/mongodb (sts), argus/redis (sts), nimbus/postgres (sts),
                    nimbus/eg-server (deploy), nimbus/eg-jobs (deploy),
                    registry/k0s-registry (deploy)
  Will delete PVCs: data-{mongodb,redis,postgres}-0, recordings-pvc, k0s-registry-pvc
  Will delete PVs:  {mongodb,redis,postgres,recordings,k0s-registry}-pv
  Will reapply:     $OVERLAY  (recreates all of the above with correct claimRefs)
  Will scale up:    registry first, then dbs, then eg-* deployments
  Data on hostPath is preserved (Retain reclaim policy).
EOF

if ! confirm "Proceed with full stateful reset?"; then
  warn "aborted"
  exit 1
fi

# --- 1. Suspend ArgoCD selfHeal + prune -----------------------------------
if [ "$SKIP_ARGOCD" = 0 ]; then
  bold "[$ARGOCD_APP] suspending selfHeal + prune"
  run "$KUBECTL -n $ARGOCD_NS patch application $ARGOCD_APP --type=merge \
    -p='{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":false,\"prune\":false}}}}'"
fi

# --- 2. Scale every stateful consumer to 0 --------------------------------
bold "scaling stateful consumers to 0"
run "$KUBECTL -n argus    scale statefulset mongodb  --replicas=0"
run "$KUBECTL -n argus    scale statefulset redis    --replicas=0"
run "$KUBECTL -n nimbus   scale statefulset postgres --replicas=0"
run "$KUBECTL -n nimbus   scale deploy eg-server     --replicas=0"
run "$KUBECTL -n nimbus   scale deploy eg-jobs       --replicas=0"
run "$KUBECTL -n registry scale deploy k0s-registry  --replicas=0"

bold "waiting for pods to terminate"
if [ "$DRY_RUN" = 0 ]; then
  sleep 15
  $KUBECTL get pod -A -l 'app in (mongodb,redis,postgres,k0s-registry,eg-server,eg-jobs)' \
    --no-headers 2>/dev/null | head
fi

# --- 3. Delete all PVCs in scope ------------------------------------------
bold "deleting PVCs"
run "$KUBECTL -n argus    delete pvc data-mongodb-0 data-redis-0 --wait=true 2>/dev/null || true"
run "$KUBECTL -n nimbus   delete pvc data-postgres-0 recordings-pvc --wait=true 2>/dev/null || true"
run "$KUBECTL -n registry delete pvc k0s-registry-pvc --wait=true 2>/dev/null || true"

# --- 4. Delete all PVs (Retain → hostPath data preserved) ----------------
bold "deleting PVs"
run "$KUBECTL delete pv mongodb-pv redis-pv postgres-pv recordings-pv k0s-registry-pv --wait=true 2>/dev/null || true"

bold "sanity-checking on-disk data is still there"
if [ "$DRY_RUN" = 0 ]; then
  sudo ls /var/lib/k0s-data/mongodb /var/lib/k0s-data/redis /var/lib/k0s-data/postgres /root/recordings /var/lib/registry 2>/dev/null \
    | head
fi

# --- 5. Reapply manifests via the overlay ---------------------------------
bold "reapplying overlay $OVERLAY"
run "$KUBECTL apply -k $OVERLAY"

if [ "$DRY_RUN" = 0 ]; then
  echo
  echo "  freshly-applied PV claimRefs:"
  $KUBECTL get pv -o jsonpath='{range .items[*]}    {.metadata.name}: claimRef={.spec.claimRef.namespace}/{.spec.claimRef.name} status={.status.phase}{"\n"}{end}'
fi

# --- 6. Scale workloads back up — registry FIRST --------------------------
bold "scaling registry back up (first, so its PVC claims its PV)"
run "$KUBECTL -n registry scale deploy k0s-registry --replicas=1"
[ "$DRY_RUN" = 0 ] && $KUBECTL -n registry rollout status deploy/k0s-registry --timeout=180s

bold "scaling dbs back up"
run "$KUBECTL -n argus    scale statefulset mongodb  --replicas=1"
run "$KUBECTL -n argus    scale statefulset redis    --replicas=1"
run "$KUBECTL -n nimbus   scale statefulset postgres --replicas=1"
if [ "$DRY_RUN" = 0 ]; then
  $KUBECTL -n argus  rollout status statefulset/mongodb  --timeout=180s
  $KUBECTL -n argus  rollout status statefulset/redis    --timeout=180s
  $KUBECTL -n nimbus rollout status statefulset/postgres --timeout=180s
fi

bold "scaling eg-* deployments back up"
run "$KUBECTL -n nimbus scale deploy eg-server --replicas=1"
run "$KUBECTL -n nimbus scale deploy eg-jobs   --replicas=1"
if [ "$DRY_RUN" = 0 ]; then
  $KUBECTL -n nimbus rollout status deploy/eg-server --timeout=180s
  $KUBECTL -n nimbus rollout status deploy/eg-jobs   --timeout=180s
fi

# --- 7. Re-enable ArgoCD selfHeal + prune ---------------------------------
if [ "$SKIP_ARGOCD" = 0 ]; then
  bold "[$ARGOCD_APP] re-enabling selfHeal + prune"
  run "$KUBECTL -n $ARGOCD_NS patch application $ARGOCD_APP --type=merge \
    -p='{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":true,\"prune\":true}}}}'"
  run "$KUBECTL -n $ARGOCD_NS annotate application $ARGOCD_APP \
    argocd.argoproj.io/refresh=hard --overwrite"
fi

# --- 8. Verify everything's back ------------------------------------------
bold "Final state"
if [ "$DRY_RUN" = 0 ]; then
  echo "=== PVs ==="
  $KUBECTL get pv -o wide

  echo "=== PVCs (all stateful) ==="
  $KUBECTL -n argus    get pvc 2>/dev/null
  $KUBECTL -n nimbus   get pvc 2>/dev/null
  $KUBECTL -n registry get pvc 2>/dev/null

  echo "=== Stateful pods ==="
  $KUBECTL -n argus    get pod 2>/dev/null
  $KUBECTL -n nimbus   get pod 2>/dev/null
  $KUBECTL -n registry get pod 2>/dev/null

  echo "=== Registry catalog (should show pre-existing images) ==="
  curl -fs http://localhost:5443/v2/_catalog 2>/dev/null || warn "registry not reachable yet"

  if [ "$SKIP_ARGOCD" = 0 ]; then
    echo "=== ArgoCD status ==="
    $KUBECTL -n "$ARGOCD_NS" get application "$ARGOCD_APP" \
      -o jsonpath='Sync: {.status.sync.status}{"\n"}Health: {.status.health.status}{"\n"}'
  fi
fi

ok "reset-deployment complete"
