#!/usr/bin/env bash
# rebind-stuck-pvc.sh — recover a PersistentVolumeClaim that's stuck in
# `status.phase: Lost`.
#
# Lost happens when the bound PV's claimRef.uid no longer matches the
# PVC's UID — typically after `kubectl apply` (or ArgoCD pre-2026-04-26
# config) strips the runtime-populated claimRef.uid back to whatever the
# manifest declares. Once a PVC enters Lost it does not auto-recover;
# the PVC must be deleted and the StatefulSet's volumeClaimTemplate
# recreates it (with a fresh UID), which then binds to the same PV
# (because the PV's claimRef.{name,namespace} matches the new PVC).
#
# Data is preserved across the recreate because:
#   - PV reclaimPolicy is Retain
#   - The hostPath in the PV is unchanged
#   - The new PVC binds to the SAME PV, mounting the same hostPath
#
# Usage:
#   sudo bash scripts/rebind-stuck-pvc.sh <service> [<service>...]
#       service is one of: mongodb | redis | postgres | all
#   sudo bash scripts/rebind-stuck-pvc.sh --custom <ns> <statefulset> <pvc>
#       for one-off recovery of a service not in the canonical list
#
# Flags:
#   -y, --yes        skip the confirmation prompt
#   --dry-run        print the kubectl commands without running them
#   -h, --help       this help
#
# The script:
#   1. Pre-flight: confirms the PVC is in Lost state (refuses to touch
#      anything Bound).
#   2. Confirms with the operator (skip with -y).
#   3. Scales the StatefulSet to 0 and waits for the pod to terminate.
#   4. Deletes the broken PVC.
#   5. Scales the StatefulSet back to 1.
#   6. Waits for the new PVC to reach Bound.
#   7. Reports + verifies pod readiness.
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

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

ASSUME_YES=0
DRY_RUN=0
TARGETS=()
CUSTOM=0
CUSTOM_ARGS=()

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# Canonical service map: service name -> "<namespace> <statefulset> <pvc>"
canonical_lookup() {
  case "$1" in
    mongodb)  echo "argus  mongodb  data-mongodb-0" ;;
    redis)    echo "argus  redis    data-redis-0"   ;;
    postgres) echo "nimbus postgres data-postgres-0" ;;
    *)        return 1 ;;
  esac
}

# ---- arg parse ------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --custom)
      CUSTOM=1
      if [ "$#" -lt 4 ]; then
        echo "error: --custom requires <namespace> <statefulset> <pvc>" >&2
        exit 2
      fi
      CUSTOM_ARGS=("$2" "$3" "$4")
      shift 4
      ;;
    all)
      TARGETS=(mongodb redis postgres)
      shift
      ;;
    mongodb|redis|postgres)
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

if [ "$CUSTOM" = 0 ] && [ "${#TARGETS[@]}" -eq 0 ]; then
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

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  printf '\n%s [y/N]: ' "$prompt"
  read -r ans </dev/tty || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- core: rebind one service --------------------------------------------

rebind_one() {
  local NS="$1" SS="$2" PVC="$3"
  bold "[$NS/$SS] rebinding pvc $PVC"

  # 1. Pre-flight
  if ! $KUBECTL -n "$NS" get statefulset "$SS" >/dev/null 2>&1; then
    fail "statefulset $NS/$SS not found"
    return 1
  fi
  if ! $KUBECTL -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
    fail "pvc $NS/$PVC not found"
    return 1
  fi
  local PHASE
  PHASE=$(pvc_phase "$NS" "$PVC")
  echo "  PVC current phase: $PHASE"
  if [ "$PHASE" = "Bound" ]; then
    ok "$NS/$PVC is already Bound — nothing to do"
    return 0
  fi
  if [ "$PHASE" != "Lost" ] && [ "$PHASE" != "Pending" ]; then
    warn "$NS/$PVC is in unexpected phase '$PHASE' — refusing to touch"
    warn "expected 'Lost' or 'Pending'; rerun manually after inspecting"
    return 1
  fi

  # 2. Show what will happen + confirm
  echo "  Plan:"
  echo "    - scale $NS/statefulset/$SS to 0 replicas"
  echo "    - wait for the pod to terminate (~30-60s)"
  echo "    - delete pvc $NS/$PVC"
  echo "    - scale $NS/statefulset/$SS to 1 replica"
  echo "    - wait for the new PVC to reach Bound"
  echo "  Data on the underlying hostPath is preserved (Retain reclaim policy)."
  if ! confirm "Proceed with $NS/$SS recovery?"; then
    warn "skipped $NS/$SS"
    return 1
  fi

  # 3. Scale down
  bold "[$NS/$SS] scaling to 0"
  run "$KUBECTL -n $NS scale statefulset $SS --replicas=0"
  bold "[$NS/$SS] waiting for pod termination"
  # The label varies (some use app=mongodb, others app.kubernetes.io/name).
  # Fallback to waiting on the well-known pod name pattern: <ss-name>-0.
  run "$KUBECTL -n $NS wait --for=delete pod/${SS}-0 --timeout=120s || true"

  # 4. Delete the broken PVC
  bold "[$NS/$SS] deleting pvc $PVC"
  run "$KUBECTL -n $NS delete pvc $PVC"

  # 5. Scale back up
  bold "[$NS/$SS] scaling back to 1"
  run "$KUBECTL -n $NS scale statefulset $SS --replicas=1"

  # 6. Wait for binding
  bold "[$NS/$SS] waiting for new PVC to bind"
  if [ "$DRY_RUN" = 1 ]; then
    ok "(dry-run) skipping bind-wait"
  else
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
    else
      fail "$NS/$PVC did not reach Bound within 120s; current phase '$NEW_PHASE'"
      return 1
    fi
  fi

  # 7. Verify pod readiness
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

# ---- driver ---------------------------------------------------------------

bold "Rebind stuck PVCs"
echo "  kubectl: $KUBECTL"
[ "$DRY_RUN" = 1 ] && echo "  --dry-run: ON (no changes will be made)"
[ "$ASSUME_YES" = 1 ] && echo "  --yes: ON (no confirmation prompts)"

failures=0

if [ "$CUSTOM" = 1 ]; then
  rebind_one "${CUSTOM_ARGS[0]}" "${CUSTOM_ARGS[1]}" "${CUSTOM_ARGS[2]}" || failures=$((failures + 1))
fi

for svc in "${TARGETS[@]:-}"; do
  [ -z "${svc:-}" ] && continue
  IFS=' ' read -r ns ss pvc <<<"$(canonical_lookup "$svc" | tr -s ' ')"
  rebind_one "$ns" "$ss" "$pvc" || failures=$((failures + 1))
done

bold "Summary"
if [ "$failures" -eq 0 ]; then
  ok "all targets recovered"
else
  fail "$failures target(s) failed; see output above"
fi
exit "$failures"
