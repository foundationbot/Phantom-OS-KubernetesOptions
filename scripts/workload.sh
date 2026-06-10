#!/usr/bin/env bash
# workload.sh — generic status / logs for any labelled workload pod.
#
# A thin, kubectl-resolving wrapper so the phantomos-ops TUI (and
# operators) can inspect ANY app.kubernetes.io/name workload without a
# per-workload script. Resolves `kubectl` on dev laptops and
# `k0s kubectl` on robots, the same way positronic.sh does.
#
# Usage:
#   workload.sh status <namespace> <app-name>
#   workload.sh logs   <namespace> <app-name> [-f] [extra kubectl logs args]
#
# Examples:
#   workload.sh status positronic phantom-locomotion
#   workload.sh logs   phantom    dma-bridge -f
set -u -o pipefail

KUBECTL=""
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
else
  echo "error: neither kubectl nor 'k0s kubectl' is available on this host" >&2
  exit 2
fi

action="${1:-}"
ns="${2:-}"
name="${3:-}"
if [ -z "$action" ] || [ -z "$ns" ] || [ -z "$name" ]; then
  echo "usage: workload.sh <status|logs> <namespace> <app-name> [args]" >&2
  exit 2
fi
shift 3
sel="app.kubernetes.io/name=$name"

case "$action" in
  status)
    printf '\n== controllers (%s/%s) ==\n' "$ns" "$name"
    $KUBECTL -n "$ns" get ds,deploy -l "$sel" -o wide 2>/dev/null
    printf '\n== pods ==\n'
    $KUBECTL -n "$ns" get pods -l "$sel" -o wide
    printf '\n== container restarts ==\n'
    $KUBECTL -n "$ns" get pods -l "$sel" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.containerStatuses[*]}  {.name}  ready={.ready}  restarts={.restartCount}{"\n"}{end}{end}' 2>/dev/null
    echo
    ;;
  logs)
    # --all-containers + --prefix so multi-container pods (e.g. the
    # phantom-sonic stack) interleave readably. Default to a bounded
    # tail; pass -f to follow.
    exec $KUBECTL -n "$ns" logs -l "$sel" \
      --all-containers --prefix --tail="${WORKLOAD_TAIL:-200}" "$@"
    ;;
  *)
    echo "error: unknown action '$action' (want: status | logs)" >&2
    exit 2
    ;;
esac
