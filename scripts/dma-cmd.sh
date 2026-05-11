#!/usr/bin/env bash
# dma-cmd.sh — run `dma-cmd` inside the dma-recorder pod for a robot.
#
# `dma-cmd` is the DMA.ethercat IPC client that pushes opcodes onto the
# host's /dev/shm /commands queue and reads acks from
# /command_responses. It only works where /dev/shm is mapped to the
# master — on a robot, that is inside one of the dma-recorder DaemonSet
# pods (hostIPC: true + /dev/shm hostPath mount). This wrapper picks
# the right pod and exec's `dma-cmd` so day-to-day record/ping calls
# don't drag along the
#   kubectl -n phantom get pod -l app.kubernetes.io/name=dma-recorder ...
# boilerplate.
#
# Usage:
#   bash scripts/dma-cmd.sh [--robot R] [--dry-run] <dma-cmd args...>
#
# Common forms:
#   bash scripts/dma-cmd.sh record start
#   bash scripts/dma-cmd.sh record stop
#   bash scripts/dma-cmd.sh ping
#   bash scripts/dma-cmd.sh record start --no-wait --timeout 5
#   bash scripts/dma-cmd.sh raw 0x0700
#   bash scripts/dma-cmd.sh --robot hwthor01 record start
#
# Targeting:
#   --robot <name>   route to the recorder pod on that k8s NODE NAME
#                    (what `kubectl get nodes` shows — e.g. hw-thor01,
#                    NOT the robot identity in /etc/phantomos/robot).
#                    Optional: with a single-node cluster (the usual
#                    case for k0s on a robot, or a kubeconfig pointed
#                    at one) the unique recorder pod is auto-picked.
#                    Required when multiple has-recorder nodes exist.
#   --dry-run        print the kubectl line without executing.
#   -h, --help       show this help.
#
# Everything else, including dma-cmd flags (--no-wait, --timeout N) and
# positional args (record start, ping, raw 0x...), is forwarded to
# dma-cmd verbatim. dma-cmd's exit code is propagated:
#   0 OK ack received    1 non-OK status   2 master not running
#   3 timeout            64 bad arg
#
# Companion to:
#   scripts/positronic.sh   — positronic-control / phantom-locomotion ops

set -u -o pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
NAMESPACE="${NAMESPACE:-phantom}"
APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=dma-recorder}"
CONTAINER_NAME="${CONTAINER_NAME:-recorder}"

ROBOT="${ROBOT:-}"
DRY_RUN=0


die()  { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
warn() { printf 'warn: %s\n' "$1" >&2; }

# ---------- kubectl resolution -------------------------------------------

KUBECTL=""
resolve_kubectl() {
  [ -n "$KUBECTL" ] && return 0
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"; return 0; fi
  if command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
    KUBECTL="k0s kubectl"; return 0
  fi
  return 1
}

require_kubectl() {
  resolve_kubectl && return 0
  if [ "$DRY_RUN" = 1 ]; then
    KUBECTL="kubectl"
    warn "no kubectl backend — dry-run will use 'kubectl' as a placeholder"
    return 0
  fi
  die "neither kubectl nor 'k0s kubectl' is available on this host" 2
}

# ---------- arg parsing --------------------------------------------------

# Strip wrapper-only flags out of "$@". Anything we don't recognise (and
# anything past `--`) is collected into REST_ARGS and forwarded to dma-cmd.
REST_ARGS=()
parse_wrapper_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --robot)
        shift; [ $# -gt 0 ] || die "--robot needs a value"
        ROBOT="$1"; shift ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      -h|--help)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      --)
        shift; REST_ARGS+=("$@"); return 0 ;;
      *)
        REST_ARGS+=("$1"); shift ;;
    esac
  done
}

# ---------- pod lookup ---------------------------------------------------

# Echo the recorder pod name. Honors --robot/ROBOT (or
# /etc/phantomos/robot if we're on a robot). With multiple candidates
# and no robot resolved, prints the list and exits non-zero (caller
# must propagate, since this runs in $() and die only exits the
# subshell).
pick_pod() {
  # --robot is the k8s NODE NAME (what `kubectl get nodes` shows), not
  # the robot identity in /etc/phantomos/robot. They often differ
  # (e.g. node=hw-thor01 vs robot=hwthor01). Don't auto-default — k0s
  # clusters are single-node and a kubeconfig pointed at a robot also
  # has only one matching node, so the unique-pod path covers both.
  local fs=(--field-selector="status.phase=Running")
  if [ -n "$ROBOT" ]; then
    fs=(--field-selector="spec.nodeName=$ROBOT,status.phase=Running")
  fi

  local pods
  pods="$($KUBECTL -n "$NAMESPACE" get pod -l "$APP_LABEL" "${fs[@]}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' \
            2>/dev/null || true)"

  local count
  count="$(printf '%s' "$pods" | grep -c . || true)"
  if [ "$count" = 0 ]; then
    if [ -n "$ROBOT" ]; then
      die "no Running dma-recorder pod on node '$ROBOT' (label=$APP_LABEL ns=$NAMESPACE)" 2
    fi
    die "no Running dma-recorder pod (label=$APP_LABEL ns=$NAMESPACE)" 2
  fi
  if [ "$count" -gt 1 ]; then
    warn "multiple dma-recorder pods found:"
    printf '%s\n' "$pods" | awk -F'\t' '{printf "  %-50s %s\n", $1, $2}' >&2
    die "use --robot <node> to pick one" 2
  fi
  printf '%s' "$pods" | head -n1 | cut -f1
}

# ---------- main ---------------------------------------------------------

main() {
  parse_wrapper_args "$@"
  require_kubectl

  if [ "${#REST_ARGS[@]}" -eq 0 ]; then
    die "no dma-cmd args (try: record start | record stop | ping; --help for more)"
  fi

  local pod=""
  if [ "$DRY_RUN" = 1 ]; then
    # Dry-run must not touch the cluster — use a placeholder so the
    # printed kubectl line is still readable.
    pod="${ROBOT:+$ROBOT-}<recorder-pod>"
  else
    pod="$(pick_pod)" || exit $?
    [ -n "$pod" ] || die "internal: empty pod name"
  fi

  local args=(-n "$NAMESPACE" exec "$pod" -c "$CONTAINER_NAME" -- dma-cmd "${REST_ARGS[@]}")

  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s' "$KUBECTL"
    for a in "${args[@]}"; do printf ' %q' "$a"; done
    printf '\n'
    return 0
  fi
  exec $KUBECTL "${args[@]}"
}

main "$@"
