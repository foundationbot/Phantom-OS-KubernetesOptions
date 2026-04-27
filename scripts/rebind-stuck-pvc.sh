#!/usr/bin/env bash
# rebind-stuck-pvc.sh — recover a PersistentVolumeClaim that's stuck in
# `status.phase: Lost`.
#
# Lost happens when the bound PV's claimRef.uid no longer matches the
# PVC's UID — typically after `kubectl apply` (or ArgoCD pre-2026-04-26
# config) strips the runtime-populated claimRef.uid back to whatever the
# manifest declares. Once a PVC enters Lost it does not auto-recover;
# the PVC must be deleted and recreated, after which it binds to the
# same PV (because the PV's claimRef.{name,namespace} matches the new
# PVC).
#
# Data is preserved across the recreate because:
#   - PV reclaimPolicy is Retain
#   - The hostPath in the PV is unchanged
#   - The new PVC binds to the SAME PV, mounting the same hostPath
#
# Two recovery patterns, depending on what owns the PVC:
#
#   Pattern A — StatefulSet-owned PVC (mongodb, redis, postgres)
#       The PVC is auto-created by the StatefulSet's volumeClaimTemplates.
#       Recovery: scale STS to 0, delete PVC, scale STS to 1 — the
#       StatefulSet recreates the PVC with a fresh UID.
#
#   Pattern B — Deployment-mounted PVC (recordings)
#       The PVC is a static manifest mounted into one or more Deployments.
#       Recovery: scale all consumer Deployments to 0, delete PVC,
#       kubectl apply -f the manifest to recreate it, scale Deployments
#       back up.
#
# Usage:
#   sudo bash scripts/rebind-stuck-pvc.sh <service> [<service>...]
#       service is one of: mongodb | redis | postgres | recordings | all
#
#   sudo bash scripts/rebind-stuck-pvc.sh --custom-sts <ns> <statefulset> <pvc>
#       Pattern A for an arbitrary StatefulSet+PVC.
#
#   sudo bash scripts/rebind-stuck-pvc.sh --custom-deploy <ns> <deploy1[,deploy2,...]> <pvc> <manifest-relpath>
#       Pattern B for an arbitrary Deployment-set+PVC.
#       manifest-relpath is relative to the repo root (e.g.
#       manifests/base/nimbus/recordings-volume.yaml).
#
# Flags:
#   -y, --yes        skip the confirmation prompt
#   --dry-run        print the kubectl commands without running them
#   -h, --help       this help
#
# Companion of:
#   - scripts/resize-registry-pvc.sh — recreate-dance for the registry PVC
#   - scripts/diagnose-positronic.sh — pod-level diagnostic

set -u -o pipefail

# kubectl resolution — robot has only `k0s kubectl`; laptops may have either.
KUBECTL=""
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
fi

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

ASSUME_YES=0
DRY_RUN=0
TARGETS=()
CUSTOM_STS=0
CUSTOM_STS_ARGS=()
CUSTOM_DEPLOY=0
CUSTOM_DEPLOY_ARGS=()

usage() {
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
}

# Canonical service map: service name -> "<type>|<ns>|<...>".
#
#   sts    | <ns> | <statefulset>          | <pvc>
#   deploy | <ns> | <deploy1[,deploy2,..]> | <pvc> | <manifest-relpath>
canonical_lookup() {
  case "$1" in
    mongodb)    echo "sts|argus|mongodb|data-mongodb-0" ;;
    redis)      echo "sts|argus|redis|data-redis-0" ;;
    postgres)   echo "sts|nimbus|postgres|data-postgres-0" ;;
    recordings) echo "deploy|nimbus|eg-server,eg-jobs|recordings-pvc|manifests/base/nimbus/recordings-volume.yaml" ;;
    *)          return 1 ;;
  esac
}

# ---- arg parse ------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --custom-sts|--custom)   # --custom is a backward-compat alias
      CUSTOM_STS=1
      if [ "$#" -lt 4 ]; then
        echo "error: $1 requires <namespace> <statefulset> <pvc>" >&2
        exit 2
      fi
      CUSTOM_STS_ARGS=("$2" "$3" "$4")
      shift 4
      ;;
    --custom-deploy)
      CUSTOM_DEPLOY=1
      if [ "$#" -lt 5 ]; then
        echo "error: --custom-deploy requires <namespace> <deploy1[,deploy2,...]> <pvc> <manifest-relpath>" >&2
        exit 2
      fi
      CUSTOM_DEPLOY_ARGS=("$2" "$3" "$4" "$5")
      shift 5
      ;;
    all)
      TARGETS=(mongodb redis postgres recordings)
      shift
      ;;
    mongodb|redis|postgres|recordings)
      TARGETS+=("$1")
      shift
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "error: unknown service: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CUSTOM_STS" = 0 ] && [ "$CUSTOM_DEPLOY" = 0 ] && [ "${#TARGETS[@]}" -eq 0 ]; then
  usage
  exit 0
fi

if [ -z "$KUBECTL" ]; then
  fail "neither kubectl nor 'k0s kubectl' is available on this host"
  exit 2
fi

# ---- helpers --------------------------------------------------------------

run() {
  printf '    $ %s\n' "$*"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  eval "$@"
}

pvc_phase() {
  local ns="$1" name="$2"
  $KUBECTL -n "$ns" get pvc "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

deploy_replicas() {
  local ns="$1" name="$2"
  $KUBECTL -n "$ns" get deploy "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || true
}

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  printf '\n%s [y/N]: ' "$prompt"
  read -r ans </dev/tty || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Validate PVC phase. Echoes the phase. Returns:
#   0 = needs recovery (Lost or Pending)
#   1 = already Bound (caller should skip)
#   2 = unexpected phase (caller should bail)
check_pvc_phase() {
  local NS="$1" PVC="$2"
  if ! $KUBECTL -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
    fail "pvc $NS/$PVC not found"
    return 2
  fi
  local PHASE
  PHASE=$(pvc_phase "$NS" "$PVC")
  echo "  PVC current phase: $PHASE"
  if [ "$PHASE" = "Bound" ]; then
    ok "$NS/$PVC is already Bound — nothing to do"
    return 1
  fi
  if [ "$PHASE" != "Lost" ] && [ "$PHASE" != "Pending" ]; then
    warn "$NS/$PVC is in unexpected phase '$PHASE' — refusing to touch"
    warn "expected 'Lost' or 'Pending'; rerun manually after inspecting"
    return 2
  fi
  return 0
}

wait_for_pvc_bound() {
  local NS="$1" PVC="$2"
  if [ "$DRY_RUN" = 1 ]; then
    ok "(dry-run) skipping bind-wait"
    return 0
  fi
  local i NEW_PHASE=""
  for i in $(seq 1 60); do
    NEW_PHASE=$(pvc_phase "$NS" "$PVC")
    [ "$NEW_PHASE" = "Bound" ] && break
    printf '    waiting (%ds): pvc phase = %s\r' "$i" "${NEW_PHASE:-(absent)}"
    sleep 2
  done
  echo
  if [ "$NEW_PHASE" = "Bound" ]; then
    ok "$NS/$PVC -> Bound"
    return 0
  fi
  fail "$NS/$PVC did not reach Bound within 120s; current phase '$NEW_PHASE'"
  return 1
}

# After the broken PVC is deleted, the PV transitions to Released (not
# Available), because its claimRef.uid still references the deleted PVC's
# UID. Released PVs do not bind to new claims. Clearing claimRef puts
# the PV back to Available, after which the new PVC binds via
# characteristic matching (size + accessModes + storageClassName).
#
# Caller passes the PV name captured BEFORE the PVC was deleted (via
# pvc_volume_name), so we know which PV to operate on.
pvc_volume_name() {
  local ns="$1" name="$2"
  $KUBECTL -n "$ns" get pvc "$name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true
}

clear_stale_pv_claimref() {
  local PV="$1"
  if [ -z "$PV" ]; then
    warn "no PV name captured — skipping claimRef clear (binding may fail if PV is Released)"
    return 0
  fi
  if ! $KUBECTL get pv "$PV" >/dev/null 2>&1; then
    warn "PV $PV not found (skipping claimRef clear)"
    return 0
  fi
  local PHASE
  PHASE=$($KUBECTL get pv "$PV" -o jsonpath='{.status.phase}' 2>/dev/null)
  bold "[pv/$PV] clearing stale claimRef (PV was: ${PHASE:-unknown})"
  run "$KUBECTL patch pv $PV --type=merge -p='{\"spec\":{\"claimRef\":null}}'"
}

# ---- pattern A: StatefulSet-owned PVC ------------------------------------

rebind_statefulset() {
  local NS="$1" SS="$2" PVC="$3"
  bold "[$NS/$SS] rebinding pvc $PVC (StatefulSet-owned)"

  if ! $KUBECTL -n "$NS" get statefulset "$SS" >/dev/null 2>&1; then
    fail "statefulset $NS/$SS not found"
    return 1
  fi
  check_pvc_phase "$NS" "$PVC"
  case $? in
    0) : ;;          # needs recovery; continue
    1) return 0 ;;   # already Bound; nothing to do
    *) return 1 ;;
  esac

  echo "  Plan:"
  echo "    - scale $NS/statefulset/$SS to 0 replicas"
  echo "    - wait for the pod to terminate (~30-60s)"
  echo "    - capture which PV the broken PVC is bound to (so we can clear its claimRef)"
  echo "    - delete pvc $NS/$PVC"
  echo "    - clear the stale claimRef on the captured PV (Released -> Available)"
  echo "    - scale $NS/statefulset/$SS to 1 replica (StatefulSet recreates the PVC)"
  echo "    - wait for the new PVC to reach Bound"
  echo "  Data on the underlying hostPath is preserved (Retain reclaim policy)."
  if ! confirm "Proceed with $NS/$SS recovery?"; then
    warn "skipped $NS/$SS"
    return 1
  fi

  bold "[$NS/$SS] scaling to 0"
  run "$KUBECTL -n $NS scale statefulset $SS --replicas=0"
  bold "[$NS/$SS] waiting for pod termination"
  run "$KUBECTL -n $NS wait --for=delete pod/${SS}-0 --timeout=120s || true"

  # Capture the PV name BEFORE the PVC is deleted; otherwise we lose the
  # only authoritative source of which PV this PVC was bound to.
  local PV
  PV=$(pvc_volume_name "$NS" "$PVC")
  echo "  (captured pvc.spec.volumeName = ${PV:-<none>})"

  bold "[$NS/$SS] deleting pvc $PVC"
  run "$KUBECTL -n $NS delete pvc $PVC"

  clear_stale_pv_claimref "$PV"

  bold "[$NS/$SS] scaling back to 1"
  run "$KUBECTL -n $NS scale statefulset $SS --replicas=1"

  bold "[$NS/$SS] waiting for new PVC to bind"
  wait_for_pvc_bound "$NS" "$PVC" || return 1

  bold "[$NS/$SS] waiting for pod readiness"
  if [ "$DRY_RUN" = 1 ]; then
    ok "(dry-run) skipping readiness wait"
  else
    if $KUBECTL -n "$NS" wait --for=condition=ready pod/"${SS}-0" --timeout=120s 2>&1; then
      ok "$NS/${SS}-0 Ready"
    else
      fail "$NS/${SS}-0 did not reach Ready within 120s"
      $KUBECTL -n "$NS" get pod "${SS}-0"
      return 1
    fi
  fi

  ok "$NS/$SS recovered"
  return 0
}

# ---- pattern B: Deployment-mounted PVC -----------------------------------

rebind_deployments() {
  local NS="$1" DEPS_CSV="$2" PVC="$3" MANIFEST_RELPATH="$4"
  local MANIFEST_ABS="${REPO_ROOT}/${MANIFEST_RELPATH}"
  local DEPS=()
  IFS=',' read -ra DEPS <<<"$DEPS_CSV"

  bold "[$NS] rebinding pvc $PVC (Deployment-mounted; consumers: ${DEPS[*]})"

  for d in "${DEPS[@]}"; do
    if ! $KUBECTL -n "$NS" get deploy "$d" >/dev/null 2>&1; then
      fail "deployment $NS/$d not found"
      return 1
    fi
  done
  if [ ! -f "$MANIFEST_ABS" ]; then
    fail "manifest not found: $MANIFEST_ABS"
    fail "(canonical entries are relative to repo root: $REPO_ROOT)"
    return 1
  fi
  check_pvc_phase "$NS" "$PVC"
  case $? in
    0) : ;;
    1) return 0 ;;
    *) return 1 ;;
  esac

  echo "  Plan:"
  echo "    - scale ${#DEPS[@]} deployment(s) (${DEPS[*]}) to 0 replicas each"
  echo "    - wait for each deployment's pods to terminate"
  echo "    - capture which PV the broken PVC is bound to (so we can clear its claimRef)"
  echo "    - delete pvc $NS/$PVC"
  echo "    - clear the stale claimRef on the captured PV (Released -> Available)"
  echo "    - kubectl apply -f $MANIFEST_RELPATH (recreates the PVC)"
  echo "    - wait for the new PVC to reach Bound"
  echo "    - scale deployments back to 1"
  echo "  Data on the underlying hostPath is preserved (Retain reclaim policy)."
  if ! confirm "Proceed with $NS/$PVC recovery?"; then
    warn "skipped $NS/$PVC"
    return 1
  fi

  for d in "${DEPS[@]}"; do
    bold "[$NS/$d] scaling to 0"
    run "$KUBECTL -n $NS scale deploy $d --replicas=0"
  done

  bold "[$NS] waiting for deployment scale-down to complete"
  if [ "$DRY_RUN" = 1 ]; then
    ok "(dry-run) skipping replica-count wait"
  else
    for d in "${DEPS[@]}"; do
      local i replicas=""
      for i in $(seq 1 60); do
        replicas=$(deploy_replicas "$NS" "$d")
        if [ -z "$replicas" ] || [ "$replicas" = "0" ]; then
          ok "$NS/$d scaled down (replicas=$replicas)"
          break
        fi
        printf '    %s/%s waiting (%ds): replicas=%s\r' "$NS" "$d" "$i" "$replicas"
        sleep 2
      done
      echo
    done
  fi

  # Capture the PV name BEFORE the PVC is deleted.
  local PV
  PV=$(pvc_volume_name "$NS" "$PVC")
  echo "  (captured pvc.spec.volumeName = ${PV:-<none>})"

  bold "[$NS/$PVC] deleting"
  run "$KUBECTL -n $NS delete pvc $PVC"

  clear_stale_pv_claimref "$PV"

  bold "[$NS/$PVC] recreating from $MANIFEST_RELPATH"
  run "$KUBECTL apply -f $MANIFEST_ABS"

  bold "[$NS/$PVC] waiting for new PVC to bind"
  wait_for_pvc_bound "$NS" "$PVC" || return 1

  for d in "${DEPS[@]}"; do
    bold "[$NS/$d] scaling back to 1"
    run "$KUBECTL -n $NS scale deploy $d --replicas=1"
  done

  bold "[$NS] waiting for deployment readiness"
  if [ "$DRY_RUN" = 1 ]; then
    ok "(dry-run) skipping rollout-status"
  else
    for d in "${DEPS[@]}"; do
      if $KUBECTL -n "$NS" rollout status deploy "$d" --timeout=120s; then
        ok "$NS/$d Ready"
      else
        fail "$NS/$d did not become Ready within 120s"
        $KUBECTL -n "$NS" get pod -l "app=$d" 2>/dev/null
        return 1
      fi
    done
  fi

  ok "$NS/$PVC + deployments recovered"
  return 0
}

# ---- dispatcher ----------------------------------------------------------

rebind_one() {
  local svc="$1"
  local entry
  entry=$(canonical_lookup "$svc") || { fail "unknown service: $svc"; return 1; }
  local type
  type=$(printf '%s' "$entry" | cut -d'|' -f1)
  case "$type" in
    sts)
      local _t ns ss pvc
      IFS='|' read -r _t ns ss pvc <<<"$entry"
      rebind_statefulset "$ns" "$ss" "$pvc"
      ;;
    deploy)
      local _t ns deps pvc manifest
      IFS='|' read -r _t ns deps pvc manifest <<<"$entry"
      rebind_deployments "$ns" "$deps" "$pvc" "$manifest"
      ;;
    *)
      fail "internal: unknown canonical type '$type' for service '$svc'"
      return 1
      ;;
  esac
}

# ---- driver ---------------------------------------------------------------

bold "Rebind stuck PVCs"
echo "  kubectl:   $KUBECTL"
echo "  repo root: $REPO_ROOT"
[ "$DRY_RUN" = 1 ] && echo "  --dry-run: ON (no changes will be made)"
[ "$ASSUME_YES" = 1 ] && echo "  --yes: ON (no confirmation prompts)"

failures=0

if [ "$CUSTOM_STS" = 1 ]; then
  rebind_statefulset "${CUSTOM_STS_ARGS[0]}" "${CUSTOM_STS_ARGS[1]}" "${CUSTOM_STS_ARGS[2]}" \
    || failures=$((failures + 1))
fi

if [ "$CUSTOM_DEPLOY" = 1 ]; then
  rebind_deployments "${CUSTOM_DEPLOY_ARGS[0]}" "${CUSTOM_DEPLOY_ARGS[1]}" "${CUSTOM_DEPLOY_ARGS[2]}" "${CUSTOM_DEPLOY_ARGS[3]}" \
    || failures=$((failures + 1))
fi

for svc in "${TARGETS[@]:-}"; do
  [ -z "${svc:-}" ] && continue
  rebind_one "$svc" || failures=$((failures + 1))
done

bold "Summary"
if [ "$failures" -eq 0 ]; then
  ok "all targets recovered"
else
  fail "$failures target(s) failed; see output above"
fi
exit "$failures"
