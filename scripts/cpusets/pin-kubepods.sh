#!/bin/bash
#
# pin-kubepods.sh — constrain the k0s pod cgroup (kubepods) to a fixed
# housekeeping CPU set, off the real-time / EtherCAT cores.
#
# Why this exists (and why it is NOT part of manage_cpusets.sh's uniform
# slice shrink): the cpuset framework's shrink_sibling_slices() writes the
# SAME housekeeping set (online − isolated partitions) to every managed
# slice, including kubepods. That produces a two-group layout. We want a
# THREE-group layout — pods on a strict subset, distinct from the rest of
# housekeeping — which the uniform shrink cannot express.
#
# It also fixes two problems the uniform path can't on this fleet:
#   1. kubepods is a cgroupfs cgroup created by k0s/kubelet AFTER boot, so
#      cpusets.service (ordered Before=k0scontroller) never sees it — the
#      kubepods cpuset is left at all-CPUs (0-N) and is unmanaged.
#   2. A `systemctl restart k0scontroller` mid-life re-creates kubepods at
#      all-CPUs, which (a) lets pods land on the isolated cores and
#      (b) flips the RT partition to `isolated invalid` because a sibling
#      cgroup now claims the partition's CPUs.
#      See docs/internal/rfcs/0003-kubelet-cpu-reservation.md (the native
#      kubelet `reservedSystemCPUs` path is unusable on Jetson Thor — the
#      kernel reports every logical CPU as CoreID=0, so the static CPU
#      manager's full-pcpus-only rule reserves all cores at once).
#
# This script is the targeted fix: write the pod cpuset directly, and
# re-assert the isolated partitions afterwards so the RT cores recover.
# A systemd unit (install) re-runs it on every k0s (re)start.
#
# Usage:
#   pin-kubepods.sh apply <cpus>        # write cpus to the kubepods cgroup now
#   pin-kubepods.sh install <cpus>      # install + enable kubepods-cpuset.service
#   pin-kubepods.sh uninstall           # disable + remove the service
#   pin-kubepods.sh status
#   pin-kubepods.sh help
#
# <cpus> is a kernel cpu-list (e.g. "0-9", "0-7,9").
#
# Vendored-tree sibling of manage_cpusets.sh; same set -u / explicit-die
# convention (NOT set -e). See VENDORED.md for the divergence policy.

set -u

PROG="$(basename "$0")"

# ---------- locations (mirror manage_cpusets.sh install convention) --------
INSTALL_DIR="/usr/local/lib/manage_cpusets"
INSTALLED_SCRIPT="$INSTALL_DIR/pin-kubepods.sh"
WRAPPER="/usr/local/sbin/pin-kubepods"
UNIT_PATH="/etc/systemd/system/kubepods-cpuset.service"
CPUSETS_CONF="${CPUSETS_CONF:-/etc/cpusets.conf}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
# k0s creates kubepods a few seconds after the controller comes up; wait.
WAIT_SECONDS="${PIN_KUBEPODS_WAIT_SECONDS:-90}"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

info() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------- cpu-list helpers ----------------------------------------------
_valid_cpu_list() {
    [[ "$1" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]
}

# ---------- locate the pod cgroup -----------------------------------------
# cgroupfs driver: $CGROUP_ROOT/kubepods ; systemd driver: kubepods.slice.
_kubepods_path() {
    local p
    for p in "$CGROUP_ROOT/kubepods" "$CGROUP_ROOT/kubepods.slice"; do
        [ -f "$p/cpuset.cpus" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# Wait up to WAIT_SECONDS for the pod cgroup to appear. Echoes the path on
# success; returns 1 on timeout.
_wait_kubepods() {
    local waited=0 path
    while :; do
        if path="$(_kubepods_path)"; then
            printf '%s\n' "$path"
            return 0
        fi
        [ "$waited" -ge "$WAIT_SECONDS" ] && return 1
        sleep 2
        waited=$((waited + 2))
    done
}

# Re-assert every isolated partition declared in cpusets.conf. Shrinking
# kubepods removes the sibling that was claiming the RT cpus, but cgroup-v2
# does not auto-recover an "isolated invalid" partition — it must be
# re-written. Idempotent: writing "isolated" to an already-valid partition
# is a no-op.
_reassert_partitions() {
    [ -r "$CPUSETS_CONF" ] || return 0
    local name slice part
    while IFS= read -r name; do
        slice="$CGROUP_ROOT/${name}.slice"
        part="$slice/cpuset.cpus.partition"
        # Only touch cgroups that are meant to be isolated partitions
        # (non-empty cpuset.cpus.exclusive).
        [ -f "$part" ] || continue
        [ -s "$slice/cpuset.cpus.exclusive" ] || continue
        local state
        state="$(cat "$part" 2>/dev/null || echo "")"
        case "$state" in
            isolated) : ;;                       # already valid, nothing to do
            *)
                if echo isolated | $SUDO tee "$part" >/dev/null 2>&1; then
                    info "  re-asserted partition '$name' (was: $state)"
                else
                    info "  WARNING: could not re-assert partition '$name'"
                fi
                ;;
        esac
    done < <(grep -oE '^\[[A-Za-z_][A-Za-z0-9_]*\]' "$CPUSETS_CONF" 2>/dev/null | tr -d '[]')
}

# ---------- subcommands ----------------------------------------------------
cmd_apply() {
    local cpus="${1:-}"
    [ -n "$cpus" ] || die "usage: $PROG apply <cpus>"
    _valid_cpu_list "$cpus" || die "invalid cpu-list: '$cpus' (expected e.g. '0-9')"

    local kp
    if ! kp="$(_wait_kubepods)"; then
        # k0s/kubelet hasn't created the pod cgroup. Nothing to pin yet —
        # not an error (the unit re-runs on the next k0s start). Exit 0 so
        # a transient k0s-down doesn't leave a failed unit.
        info "$PROG: kubepods cgroup not present after ${WAIT_SECONDS}s — k0s not up? Skipping."
        return 0
    fi

    local cur
    cur="$(cat "$kp/cpuset.cpus" 2>/dev/null || echo "")"
    if [ "$cur" != "$cpus" ]; then
        echo "$cpus" | $SUDO tee "$kp/cpuset.cpus" >/dev/null \
            || die "failed to write $kp/cpuset.cpus"
    fi

    local eff
    eff="$(cat "$kp/cpuset.cpus.effective" 2>/dev/null || echo "")"
    [ "$eff" = "$cpus" ] \
        || die "kubepods cpuset.cpus.effective='$eff' != requested '$cpus'"
    info "$PROG: kubepods pinned to $cpus ($kp)"

    _reassert_partitions
    return 0
}

cmd_install() {
    local cpus="${1:-}"
    [ -n "$cpus" ] || die "usage: $PROG install <cpus>"
    _valid_cpu_list "$cpus" || die "invalid cpu-list: '$cpus'"

    # 1. Copy this script to the self-contained install dir (survives the
    #    source tree moving), mirroring manage_cpusets.sh install-service.
    local src
    src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    $SUDO mkdir -p "$INSTALL_DIR"
    if [ "$src" != "$INSTALLED_SCRIPT" ]; then
        $SUDO install -m 0755 "$src" "$INSTALLED_SCRIPT" \
            || die "failed to copy $src -> $INSTALLED_SCRIPT"
    fi

    # 2. Wrapper with the cpu-list baked in (single source of truth is the
    #    caller / host-config.yaml), mirroring /usr/local/sbin/apply-cpusets.
    local tmp
    tmp="$(mktemp)" || die "mktemp failed"
    cat > "$tmp" <<EOF
#!/bin/bash
exec "$INSTALLED_SCRIPT" apply "$cpus" "\$@"
EOF
    $SUDO install -m 0755 "$tmp" "$WRAPPER" || { rm -f "$tmp"; die "install wrapper failed"; }
    rm -f "$tmp"

    # 3. systemd unit. Ordered + lifecycle-bound to k0scontroller so it
    #    re-asserts the pin on every k0s (re)start, not just at boot:
    #      After=     — run after k0s has (re)started
    #      PartOf=    — k0s stop/restart propagates to this unit
    #      WantedBy=  — enabling pulls it in whenever k0s starts
    tmp="$(mktemp)" || die "mktemp failed"
    cat > "$tmp" <<EOF
[Unit]
Description=Pin k0s pod cgroup (kubepods) to housekeeping CPUs $cpus, off the RT cores
Documentation=https://github.com/foundation/Phantom-OS-KubernetesOptions/blob/main/docs/internal/rfcs/0003-kubelet-cpu-reservation.md
After=k0scontroller.service
PartOf=k0scontroller.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=150
ExecStart=$WRAPPER

[Install]
WantedBy=k0scontroller.service
EOF
    $SUDO install -m 0644 "$tmp" "$UNIT_PATH" || { rm -f "$tmp"; die "install unit failed"; }
    rm -f "$tmp"

    $SUDO systemctl daemon-reload || die "systemctl daemon-reload failed"
    $SUDO systemctl enable kubepods-cpuset.service >/dev/null 2>&1 \
        || die "systemctl enable failed"
    # start now → applies the pin live (and re-asserts partitions).
    $SUDO systemctl restart kubepods-cpuset.service \
        || die "systemctl start kubepods-cpuset.service failed"

    info "$PROG: installed and enabled kubepods-cpuset.service (cpus=$cpus)"
    return 0
}

cmd_uninstall() {
    $SUDO systemctl disable --now kubepods-cpuset.service >/dev/null 2>&1 || true
    $SUDO rm -f "$UNIT_PATH" "$WRAPPER" "$INSTALLED_SCRIPT"
    $SUDO systemctl daemon-reload || true
    info "$PROG: removed kubepods-cpuset.service (the live kubepods cpuset is unchanged until k0s restarts)"
    return 0
}

cmd_status() {
    local kp
    if kp="$(_kubepods_path)"; then
        printf 'kubepods cgroup:    %s\n' "$kp"
        printf 'cpuset.cpus:        %s\n' "$(cat "$kp/cpuset.cpus" 2>/dev/null)"
        printf 'cpuset.cpus.effective: %s\n' "$(cat "$kp/cpuset.cpus.effective" 2>/dev/null)"
    else
        printf 'kubepods cgroup:    (absent — k0s not running?)\n'
    fi
    printf 'service:            %s\n' "$(systemctl is-enabled kubepods-cpuset.service 2>/dev/null || echo absent)"
    return 0
}

cmd_help() { sed -n '2,40p' "${BASH_SOURCE[0]}"; }

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        apply)        cmd_apply "$@" ;;
        install)      cmd_install "$@" ;;
        uninstall)    cmd_uninstall "$@" ;;
        status)       cmd_status "$@" ;;
        help|-h|--help) cmd_help ;;
        *) die "unknown subcommand: $cmd (try: apply install uninstall status help)" ;;
    esac
}

main "$@"
