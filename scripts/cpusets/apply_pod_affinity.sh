#!/usr/bin/env bash
# apply_pod_affinity.sh — pin host-visible pod/process trees onto specific
# CPUs by command-line match.
#
# WHY THIS EXISTS (complements manage_cpusets.sh, does not replace it):
#   - manage_cpusets.sh + the systemd CPUAffinity= drop-in keep HOUSEKEEPING
#     off the isolated cores. That only reaches systemd-managed processes.
#   - k0s pods run under containerd/kubepods, NOT systemd, so nothing places
#     them. This script pins SELECTED pod workloads ONTO chosen isolated
#     cores (e.g. the shm/video recorders and the locomotion supervisor),
#     keeping them off the noisy housekeeping cores without disturbing the
#     EtherCAT RT loop.
#
# Rules live in /etc/phantom-pod-affinity.conf, one per line:
#   <cpus>|<pgrep -f pattern>
# where <cpus> is a taskset -c list (e.g. "11" or "12-13") and the pattern
# is matched against the full command line. Blank lines and #-comments are
# ignored. Example:
#   11|dma_recorder            # .rrd shm recorder (dma_main queues -> .rrd)
#   11|dma_video.recorder      # camera recorder (-> .mp4)
#   12-13|run_residual_locomotion_supervisor
#
# Subcommands:
#   apply             read the conf and pin every matching process (all threads)
#   install [conf]    install self + conf, write & enable the timer, apply once
#   uninstall         disable + remove the units (leaves the conf)
#   status            show the conf and current affinity of matched processes
#
# FLEET CAVEAT: taskset onto an isolated core only succeeds while that core is
# still in the process's cgroup cpuset. Plain isolcpus= (the mk11test layout)
# leaves kubepods spanning every cpu, so this works. If a robot makes the
# isolated cores EXCLUSIVE cgroup-v2 partitions (manage_cpusets apply sets
# cpuset.cpus.partition=isolated), kubepods no longer contains them and
# taskset fails with EINVAL — each such pin logs a WARN and is skipped rather
# than aborting.
set -euo pipefail

CONF="${POD_AFFINITY_CONF:-/etc/phantom-pod-affinity.conf}"
INSTALL_DIR="${POD_AFFINITY_INSTALL_DIR:-/opt/phantom-cpusets}"
SELF="$INSTALL_DIR/apply_pod_affinity.sh"
SERVICE="/etc/systemd/system/phantom-pod-affinity.service"
TIMER="/etc/systemd/system/phantom-pod-affinity.timer"
INTERVAL="${POD_AFFINITY_INTERVAL:-30s}"

log() { printf '[pod-affinity] %s\n' "$*"; }
die() { printf '[pod-affinity] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" = 0 ] || die "must run as root"; }

# Iterate conf rules, invoking `_cb <cpus> <pattern>` for each.
_each_rule() {
  local cb="$1" line cpus pat
  [ -r "$CONF" ] || { log "no conf at $CONF — nothing to do"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                       # strip comments
    [ -z "${line//[[:space:]]/}" ] && continue
    cpus="${line%%|*}"; pat="${line#*|}"
    cpus="${cpus//[[:space:]]/}"
    pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$cpus" ] || [ -z "$pat" ] && continue
    "$cb" "$cpus" "$pat"
  done < "$CONF"
}

_pin_rule() {
  local cpus="$1" pat="$2" pid comm
  for pid in $(pgrep -f -- "$pat" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    # pgrep -f matches the FULL command line, so it also hits wrapper
    # processes that merely mention the pattern — the interactive ssh
    # `bash -c`, and the host-side `k0s kubectl exec ... bash -c
    # '...supervisor.py'` client. Pin only the real target binaries
    # (python3, dma_recorder, ...), never shells/exec-clients.
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in
      bash|sh|dash|zsh|ssh|sshd|sudo|su|pgrep|kubectl|k0s|containerd*|runc)
        continue ;;
    esac
    # -a = all threads of the process, -c = cpu-list format
    if taskset -a -c -p "$cpus" "$pid" >/dev/null 2>&1; then
      PIN_OK=$((PIN_OK + 1))
      log "pinned pid $pid ($pat) -> cpus $cpus"
    else
      PIN_FAIL=$((PIN_FAIL + 1))
      log "WARN could not pin pid $pid ($pat) -> $cpus (cgroup cpuset may exclude those cores)"
    fi
  done
}

cmd_apply() {
  require_root
  PIN_OK=0; PIN_FAIL=0
  _each_rule _pin_rule
  log "done: ${PIN_OK:-0} pinned, ${PIN_FAIL:-0} failed"
}

_status_rule() {
  local cpus="$1" pat="$2" pid comm shown=0
  for pid in $(pgrep -f -- "$pat" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in
      bash|sh|dash|zsh|ssh|sshd|sudo|su|pgrep|kubectl|k0s|containerd*|runc)
        continue ;;
    esac
    printf '  %-40s want=%-6s  pid=%-8s now=%s\n' \
      "$pat" "$cpus" "$pid" "$(taskset -c -p "$pid" 2>/dev/null | sed 's/.*: //')"
    shown=1
  done
  if [ "$shown" = 0 ]; then
    printf '  %-40s want=%-6s  (no process)\n' "$pat" "$cpus"
  fi
}

cmd_status() {
  echo "conf: $CONF"
  _each_rule _status_rule
}

cmd_install() {
  require_root
  local conf="${1:-$CONF}"
  [ -f "$conf" ] || die "conf not found: $conf"
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "${BASH_SOURCE[0]}" "$SELF"
  if [ "$conf" != "$CONF" ]; then
    install -m 0644 "$conf" "$CONF"
    log "installed conf -> $CONF"
  fi

  cat > "$SERVICE" <<EOF
# Auto-generated by apply_pod_affinity.sh install
[Unit]
Description=Pin selected k0s pod processes onto isolated CPUs (phantom)
Documentation=file://$SELF
# Runs after the kubelet so pods exist to be pinned; ordering only, not a hard dep.
After=k0scontroller.service k0sworker.service

[Service]
Type=oneshot
ExecStart=$SELF apply
EOF

  cat > "$TIMER" <<EOF
# Auto-generated by apply_pod_affinity.sh install
[Unit]
Description=Periodically reassert phantom pod CPU affinity (catches pod restarts)

[Timer]
OnBootSec=60s
OnUnitActiveSec=$INTERVAL
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now phantom-pod-affinity.timer
  log "installed + enabled phantom-pod-affinity.timer (reasserts every $INTERVAL)"
  cmd_apply
}

cmd_uninstall() {
  require_root
  systemctl disable --now phantom-pod-affinity.timer 2>/dev/null || true
  rm -f "$SERVICE" "$TIMER"
  systemctl daemon-reload
  log "removed phantom-pod-affinity units (conf $CONF left in place)"
}

case "${1:-}" in
  apply)     cmd_apply ;;
  install)   shift; cmd_install "${1:-}" ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *) cat >&2 <<EOF
usage: apply_pod_affinity.sh {apply|install [conf]|uninstall|status}
  apply             pin every process matching /etc/phantom-pod-affinity.conf
  install [conf]    install self+conf, enable the reassert timer, apply once
  uninstall         disable+remove the units
  status            show desired vs current affinity for matched processes
EOF
     exit 2 ;;
esac
