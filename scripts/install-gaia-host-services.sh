#!/usr/bin/env bash
# install-gaia-host-services.sh — install the gaia HOST-side services that live
# OUTSIDE k0s (they can't be ArgoCD/k8s workloads): the RAG/incident services
# (docker run foundationbot/gaia-tools) and the GPU/NVMAP node-exporter textfile
# collectors. Units + scripts ship in ../host-services/gaia/.
#
# Idempotent: re-running reinstalls the unit/script files and re-enables. Called
# by bootstrap-robot.sh (phase "gaia-host"); also runnable standalone:
#   sudo bash scripts/install-gaia-host-services.sh           # install + enable
#   sudo bash scripts/install-gaia-host-services.sh disable   # stop + disable all
#
# ACTION ($1, default "install"): "disable" tears down EVERY gaia host unit
# (including the GPU/NVMAP collectors) — used when the gaia stack is not enabled,
# so a robot without in-cluster prometheus/loki isn't left running orphaned
# collectors/servers.
#
# DRY_RUN=1 prints actions without changing the system.
set -eu

ACTION="${1:-install}"

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
SRC="$REPO_ROOT/host-services/gaia"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/gaia/node-textfile}"
DRY_RUN="${DRY_RUN:-0}"

# RAG/incident services (docker run gaia-tools). The GPU/NVMAP host metric
# collectors (gaia-gpu-metrics / gaia-nvmap-metrics + their scripts) moved to the
# phantomos-k0s deb postinst (SOF-1167 #6) so `dpkg -i` installs+enables them —
# they are intentionally NOT installed here anymore (avoids double-enable).
UNITS="gaia-ask-server.service gaia-incident-learner.service gaia-log-extractor.service"
# Every gaia host unit, regardless of who installs it — the disable path brings
# them ALL down (the deb-managed collectors included). The unit files live in
# /etc/systemd/system (NOT dpkg-owned — the deb ships its copies under
# /opt/.../host-services/gaia), so the disable path may remove them.
ALL_UNITS="$UNITS gaia-gpu-metrics.service gaia-nvmap-metrics.service"
# collector scripts the *.service ExecStart=/usr/local/bin/... expect.
SCRIPTS=""
# Files the disable path removes for a full uninstall: the collector scripts the
# metrics units' ExecStart point at.
REMOVABLE_SCRIPTS="gaia-gpu-metrics.sh jetson-nvmap-mem-textfile.sh"

run() { if [ "$DRY_RUN" = 1 ]; then echo "  DRY-RUN  $*"; else "$@"; fi; }

# disable path: stop + disable + UNINSTALL every gaia host unit on this host —
# remove the unit files and collector scripts too, so "gaia disabled" leaves
# nothing behind. The install path re-drops everything idempotently if gaia is
# re-enabled.
if [ "$ACTION" = disable ]; then
  echo "disabling + removing gaia host services (gaia stack not enabled)"
  for u in $ALL_UNITS; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      run systemctl disable --now "$u"
      echo "  disabled $u"
    fi
    if [ -f "/etc/systemd/system/$u" ]; then
      run rm -f "/etc/systemd/system/$u"
      echo "  removed /etc/systemd/system/$u"
    fi
  done
  for s in $REMOVABLE_SCRIPTS; do
    if [ -f "/usr/local/bin/$s" ]; then
      run rm -f "/usr/local/bin/$s"
      echo "  removed /usr/local/bin/$s"
    fi
  done
  run systemctl daemon-reload
  echo "done."
  exit 0
fi

if [ "$ACTION" != install ]; then
  echo "ERROR: unknown action '$ACTION' (expected install|disable)" >&2
  exit 2
fi

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
