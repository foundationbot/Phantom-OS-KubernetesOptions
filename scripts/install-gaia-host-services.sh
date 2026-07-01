#!/usr/bin/env bash
# install-gaia-host-services.sh — manage the gaia HOST-side units.
#
# As of 2026-07-01 the RAG/incident read-side (gaia-ask-server, gaia-monitor,
# gaia-incident-learner, gaia-log-extractor) was MIGRATED from host `docker run`
# systemd units to k0s workloads (manifests/base/gaia/gaia-tools.yaml). So this
# script no longer installs any docker-run units — instead it TEARS DOWN the old
# ones on every run, so a robot upgrading from the docker-era doesn't leave them
# fighting the new k0s pods for host :8200 / /data.
#
# The GPU/NVMAP node-exporter textfile collectors (gaia-gpu-metrics /
# gaia-nvmap-metrics) are NOT k8s workloads — they still install+enable straight
# from the deb postinst (SOF-1167 #6), not here.
#
# Idempotent. Called by bootstrap-robot.sh (phase "gaia-host"); also standalone:
#   sudo bash scripts/install-gaia-host-services.sh           # migrate: tear down docker units
#   sudo bash scripts/install-gaia-host-services.sh disable   # + tear down GPU/NVMAP collectors
#
# DRY_RUN=1 prints actions without changing the system.
set -eu

ACTION="${1:-install}"
DRY_RUN="${DRY_RUN:-0}"

# The RAG/incident units that moved to k0s. Torn down on every run (they run as
# pods now; leaving the docker units up double-binds host :8200 and /data).
MIGRATED_UNITS="gaia-ask-server.service gaia-monitor.service gaia-incident-learner.service gaia-log-extractor.service"
# Host node-exporter textfile collectors (deb-postinst managed) — only the
# disable path (gaia stack off) tears these down.
COLLECTOR_UNITS="gaia-gpu-metrics.service gaia-nvmap-metrics.service"
REMOVABLE_SCRIPTS="gaia-gpu-metrics.sh jetson-nvmap-mem-textfile.sh"

run() { if [ "$DRY_RUN" = 1 ]; then echo "  DRY-RUN  $*"; else "$@"; fi; }

# Stop + disable + remove a systemd unit's installed copy (units live in
# /etc/systemd/system, not dpkg-owned). Also `docker rm -f` any leftover
# container of the same name so the k0s pod can bind the host port.
teardown_unit() {
  u="$1"
  if systemctl cat "$u" >/dev/null 2>&1; then
    run systemctl disable --now "$u"
    echo "  disabled $u"
  fi
  if [ -f "/etc/systemd/system/$u" ]; then
    run rm -f "/etc/systemd/system/$u"
    echo "  removed /etc/systemd/system/$u"
  fi
  # container name == unit basename (matches the old `docker run --name`)
  cname="${u%.service}"
  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
    run docker rm -f "$cname"
    echo "  docker rm -f $cname"
  fi
}

echo "gaia host services: tearing down migrated docker units (now k0s workloads)"
for u in $MIGRATED_UNITS; do teardown_unit "$u"; done

if [ "$ACTION" = disable ]; then
  echo "gaia stack not enabled — also tearing down host metric collectors"
  for u in $COLLECTOR_UNITS; do teardown_unit "$u"; done
  for s in $REMOVABLE_SCRIPTS; do
    if [ -f "/usr/local/bin/$s" ]; then
      run rm -f "/usr/local/bin/$s"
      echo "  removed /usr/local/bin/$s"
    fi
  done
elif [ "$ACTION" != install ]; then
  echo "ERROR: unknown action '$ACTION' (expected install|disable)" >&2
  exit 2
fi

run systemctl daemon-reload
echo "done."
