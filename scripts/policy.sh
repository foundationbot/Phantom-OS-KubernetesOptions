#!/usr/bin/env bash
# policy.sh — send start/stop signals to the running policy pod.
#
# Auto-detects whether phantom-locomotion or positronic-control is
# deployed (mutually exclusive per robot — see comments in
# manifests/base/positronic/positronic-control.yaml) and exec's a
# ros2 topic pub on the matching pod/container.
#
# Usage: bash scripts/policy.sh {start|stop}
#
# Env overrides (rarely needed):
#   NAMESPACE    — defaults to "positronic"
#   LABEL        — pod selector; if set, disables auto-detect
#   CONTAINER    — exec target container; defaults to LABEL's value-after-`=`
#   START_TOPIC  — defaults to /phantom/start_startup
#   STOP_TOPIC   — defaults to /phantom/stop_policy

set -euo pipefail

NAMESPACE="${NAMESPACE:-positronic}"
START_TOPIC="${START_TOPIC:-/phantom/start_startup}"
STOP_TOPIC="${STOP_TOPIC:-/phantom/stop_policy}"

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=kubectl
elif command -v k0s >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
else
  echo "error: neither kubectl nor k0s found" >&2
  exit 2
fi

case "${1:-}" in
  start) TOPIC="$START_TOPIC" ;;
  stop)  TOPIC="$STOP_TOPIC" ;;
  *) echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac

LABELS=(
  "app.kubernetes.io/name=phantom-locomotion"
  "app=positronic-control"
)
CONTAINERS=(
  "phantom-locomotion"
  "positronic-control"
)
if [ -n "${LABEL:-}" ]; then
  LABELS=("$LABEL")
  CONTAINERS=("${CONTAINER:-${LABEL##*=}}")
fi

POD=""
CONT=""
SELECTED_LABEL=""
for i in "${!LABELS[@]}"; do
  POD="$($KUBECTL -n "$NAMESPACE" get pod -l "${LABELS[$i]}" \
         -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $1}')"
  if [ -n "$POD" ]; then
    CONT="${CONTAINERS[$i]}"
    SELECTED_LABEL="${LABELS[$i]}"
    break
  fi
done

[ -n "$POD" ] || {
  echo "error: no policy pod found in namespace $NAMESPACE (tried: ${LABELS[*]})" >&2
  exit 1
}

echo "→ targeting $POD (label=$SELECTED_LABEL, container=$CONT)" >&2

exec $KUBECTL -n "$NAMESPACE" exec "$POD" -c "$CONT" -- \
  bash -lc "source /opt/ros/\${ROS_DISTRO:-jazzy}/setup.bash && \
            ros2 topic pub --once $TOPIC std_msgs/Bool 'data: true'"
