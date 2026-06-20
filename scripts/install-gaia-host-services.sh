#!/usr/bin/env bash
# install-gaia-host-services.sh — install the gaia HOST-side services that live
# OUTSIDE k0s (they can't be ArgoCD/k8s workloads): the RAG/incident services
# (docker run foundationbot/gaia-tools) and the GPU/NVMAP node-exporter textfile
# collectors. Units + scripts ship in ../host-services/gaia/.
#
# Idempotent: re-running reinstalls the unit/script files and re-enables. Called
# by bootstrap-robot.sh (phase "gaia-host"); also runnable standalone:
#   sudo bash scripts/install-gaia-host-services.sh
#
# DRY_RUN=1 prints actions without changing the system.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
SRC="$REPO_ROOT/host-services/gaia"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/gaia/node-textfile}"
DRY_RUN="${DRY_RUN:-0}"

# RAG/incident services (docker run gaia-tools). The GPU/NVMAP host metric
# collectors (gaia-gpu-metrics / gaia-nvmap-metrics + their scripts) moved to the
# phantomos-k0s deb postinst (SOF-1167 #6) so `dpkg -i` installs+enables them —
# they are intentionally NOT managed here anymore (avoids double-enable).
UNITS="gaia-ask-server.service gaia-incident-learner.service gaia-log-extractor.service"
# collector scripts the *.service ExecStart=/usr/local/bin/... expect.
SCRIPTS=""

run() { if [ "$DRY_RUN" = 1 ]; then echo "  DRY-RUN  $*"; else "$@"; fi; }

[ -d "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

echo "installing gaia host services from $SRC"
run mkdir -p "$TEXTFILE_DIR"

for s in $SCRIPTS; do
  [ -f "$SRC/$s" ] || { echo "ERROR: missing $SRC/$s" >&2; exit 1; }
  run install -m 0755 "$SRC/$s" "/usr/local/bin/$s"
  echo "  script -> /usr/local/bin/$s"
done

for u in $UNITS; do
  [ -f "$SRC/$u" ] || { echo "ERROR: missing $SRC/$u" >&2; exit 1; }
  run install -m 0644 "$SRC/$u" "/etc/systemd/system/$u"
  echo "  unit   -> /etc/systemd/system/$u"
done

run systemctl daemon-reload
for u in $UNITS; do
  run systemctl enable --now "$u"
done

if [ "$DRY_RUN" != 1 ]; then
  echo "=== status ==="
  for u in $UNITS; do printf "  %-26s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
fi
echo "done."
