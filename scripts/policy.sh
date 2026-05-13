#!/usr/bin/env bash
# policy.sh — send start/stop signals to the phantom-locomotion policy.
#
# Usage: bash scripts/policy.sh {start|stop}

set -euo pipefail

NAMESPACE="${NAMESPACE:-positronic}"
LABEL="${LABEL:-app.kubernetes.io/name=phantom-locomotion}"
CONTAINER="${CONTAINER:-phantom-locomotion}"

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=kubectl
elif command -v k0s >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
else
  echo "error: neither kubectl nor k0s found" >&2
  exit 2
fi

case "${1:-}" in
  start) TOPIC=/phantom/start_startup ;;
  stop)  TOPIC=/phantom/stop_policy ;;
  *) echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac

POD="$($KUBECTL -n "$NAMESPACE" get pod -l "$LABEL" \
       -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || { echo "error: no phantom-locomotion pod found" >&2; exit 1; }

exec $KUBECTL -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- \
  bash -lc "source /opt/ros/jazzy/setup.bash && \
            ros2 topic pub --once $TOPIC std_msgs/Bool 'data: true'"
