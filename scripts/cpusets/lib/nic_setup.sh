#!/bin/bash
# lib/nic_setup.sh — pure-shell EtherCAT NIC setup helpers.
#
# Sourceable library. Functions only. No top-level execution beyond the
# constant defaults and the source-guard. Idempotent by design: each
# write/apply function is safe to call repeatedly, and dedicated
# inspection functions (nic_already_named, nic_udev_rule_present) let
# callers (notably bootstrap phase 7) decide whether any work needs to
# happen at all.
#
# Idempotency invariant (load-bearing):
#   If `nic_already_named <iface> <mac>` returns 0 AND
#      `nic_udev_rule_present <iface> <mac>` returns 0,
#   the host is in the desired state and no further action is required —
#   no rule rewrite, no udev reload, no rename. Bootstrap MUST guard on
#   both predicates before calling the write path to avoid the previous
#   bug where the script re-renamed an already-correct interface every
#   time it was invoked.
#
# Conventions: set -u, no set -e (matches manage_cpusets.sh). Errors are
# surfaced via return codes; messages go to stderr so stdout-capturing
# callers (e.g. nic_resolve_target_mac) get a clean MAC.
#
# Consumers:
#   - setup_ethercat_interface.sh (CLI wrapper)
#   - scripts/bootstrap-robot.sh phase 7 (sources directly)

[[ -n "${__NIC_SETUP_SH_SOURCED:-}" ]] && return 0
__NIC_SETUP_SH_SOURCED=1

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "nic_setup.sh requires bash." >&2
    return 1 2>/dev/null || exit 1
fi

# Load the discovery helpers (nic_match_by_mac/pci/driver, validators).
# Idempotent: nic_discovery.sh is itself source-guarded.
__NIC_SETUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./nic_discovery.sh
source "$__NIC_SETUP_LIB_DIR/nic_discovery.sh"

# Default udev rule file; callers may override via NIC_UDEV_RULE_FILE.
: "${NIC_UDEV_RULE_FILE:=/etc/udev/rules.d/70-ecat.rules}"

# Sudo prefix; matches the convention of the wrapping script.
if [[ -z "${NIC_SUDO+x}" ]]; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        NIC_SUDO=""
    else
        NIC_SUDO="sudo"
    fi
fi

# ---- nic_resolve_target_mac <selector-flag> <selector-value> [extra...] ----
#
# Echoes the MAC of the adapter matching the selector. Selector flags
# mirror the CLI surface so callers can pipe argv straight through:
#   --mac <aa:bb:cc:dd:ee:ff>
#   --pci <0000:01:00.0>
#   --driver <name> --index <N>
#
# Returns 0 on a unique match, 1 on no match / multiple matches / bad
# selector. Diagnostic messages go to stderr.
nic_resolve_target_mac() {
    local flag="${1:-}"
    local value="${2:-}"
    local extra_flag="${3:-}"
    local extra_value="${4:-}"

    if [[ -z "$flag" || -z "$value" ]]; then
        echo "nic_resolve_target_mac: missing selector flag/value" >&2
        return 1
    fi

    local ifname=""
    case "$flag" in
        --mac)
            ifname=$(nic_match_by_mac "$value") || return 1
            ;;
        --pci)
            ifname=$(nic_match_by_pci "$value") || return 1
            ;;
        --driver)
            if [[ "$extra_flag" != "--index" || -z "$extra_value" ]]; then
                echo "nic_resolve_target_mac: --driver requires --index <N>" >&2
                return 1
            fi
            ifname=$(nic_match_by_driver "$value" "$extra_value") || return 1
            ;;
        *)
            echo "nic_resolve_target_mac: unknown selector flag: $flag" >&2
            return 1
            ;;
    esac

    [[ -n "$ifname" ]] || return 1

    local mac
    mac=$(cat "/sys/class/net/$ifname/address" 2>/dev/null || true)
    if [[ -z "$mac" ]]; then
        echo "nic_resolve_target_mac: could not read MAC for $ifname" >&2
        return 1
    fi
    printf '%s\n' "${mac,,}"
    return 0
}

# ---- nic_resolve_target_mac_interactive <iface> ----------------------------
#
# Drives the TTY adapter picker and echoes the MAC of the chosen NIC on
# stdout. Returns 0 on success, 1 on EOF / abort / no adapters found.
# Diagnostic output and prompts go to stderr so a caller using
#     mac=$(nic_resolve_target_mac_interactive ecat0)
# sees only the MAC on stdout.
#
# Lazy-loads its dependency on nic_rt.sh helpers (find_usb_ethernet,
# find_native_ethernet, display_all_adapters) so callers — bootstrap
# phase 7 included — don't have to source nic_rt.sh up front. The
# library is large and only this one function needs it.
nic_resolve_target_mac_interactive() {
    local iface="${1:-ecat0}"

    if ! declare -F find_usb_ethernet >/dev/null \
       || ! declare -F find_native_ethernet >/dev/null \
       || ! declare -F display_all_adapters >/dev/null; then
        # shellcheck source=./nic_rt.sh
        if ! source "$__NIC_SETUP_LIB_DIR/nic_rt.sh" 2>/dev/null; then
            echo "nic_resolve_target_mac_interactive: cannot source $__NIC_SETUP_LIB_DIR/nic_rt.sh" >&2
            return 1
        fi
        if ! declare -F find_usb_ethernet >/dev/null \
           || ! declare -F find_native_ethernet >/dev/null \
           || ! declare -F display_all_adapters >/dev/null; then
            echo "nic_resolve_target_mac_interactive: nic_rt.sh did not define the expected helpers" >&2
            return 1
        fi
    fi

    if [[ ! -t 0 ]]; then
        echo "nic_resolve_target_mac_interactive: stdin is not a TTY" >&2
        return 1
    fi

    find_usb_ethernet
    find_native_ethernet

    if ! display_all_adapters >&2; then
        echo "nic_resolve_target_mac_interactive: no adapters found" >&2
        return 1
    fi

    local total
    total=$(( ${#USB_ADAPTERS[@]} + ${#NATIVE_ADAPTERS[@]} ))
    local selection=""
    if (( total == 1 )); then
        selection=1
        echo "Only one adapter found, selecting it automatically." >&2
    else
        # Prompt on stderr so stdout stays clean for the MAC.
        read -r -p "Select adapter to use for EtherCAT [1-$total]: " selection </dev/tty 2>/dev/tty
        if [[ -z "$selection" ]]; then
            echo "nic_resolve_target_mac_interactive: aborted (EOF)" >&2
            return 1
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > total )); then
            echo "nic_resolve_target_mac_interactive: invalid selection: $selection" >&2
            return 1
        fi
    fi

    local mac=""
    if (( selection <= ${#USB_ADAPTERS[@]} )); then
        local selected="${USB_ADAPTERS[$((selection-1))]}"
        IFS='|' read -r _iface _vendor _product _driver _manufacturer _product_name mac <<< "$selected"
    else
        local native_idx=$((selection - ${#USB_ADAPTERS[@]} - 1))
        local selected="${NATIVE_ADAPTERS[$native_idx]}"
        IFS='|' read -r _iface _driver mac _bus _desc _speed <<< "$selected"
    fi

    if [[ -z "$mac" ]]; then
        echo "nic_resolve_target_mac_interactive: failed to extract MAC from selection" >&2
        return 1
    fi
    printf '%s\n' "${mac,,}"
    return 0
}

# ---- nic_already_named <iface> <mac> ---------------------------------------
#
# Returns 0 if `ip link show <iface>` succeeds AND the iface's current
# MAC equals <mac> (case-insensitive). Returns 1 otherwise. No side
# effects.
#
# This is the live-state half of the idempotency invariant. A return of
# 0 means the kernel already presents the desired ifname bound to the
# desired hardware. It says NOTHING about persistence — pair with
# nic_udev_rule_present to know whether the state survives reboot.
nic_already_named() {
    local iface="${1:-}"
    local want_mac="${2:-}"
    [[ -n "$iface" && -n "$want_mac" ]] || return 1

    ip link show "$iface" >/dev/null 2>&1 || return 1

    local have_mac
    have_mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
    [[ -n "$have_mac" ]] || return 1

    [[ "${have_mac,,}" == "${want_mac,,}" ]]
}

# ---- nic_udev_rule_present <iface> <mac> -----------------------------------
#
# Returns 0 if NIC_UDEV_RULE_FILE contains a rule that binds <iface> to
# <mac>. Returns 1 if the file is missing, the file exists but contains
# no matching rule, or the file binds <iface> to a different MAC (the
# "dirty" case — caller should overwrite via nic_write_udev_rule).
# No side effects.
#
# The match is line-scoped: a single uncommented line must reference
# both the MAC (via ATTR{address}=="<mac>", case-insensitive) and the
# target name (via NAME="<iface>"). This avoids false positives where
# the file happens to mention the MAC and the iface in unrelated rules.
nic_udev_rule_present() {
    local iface="${1:-}"
    local want_mac="${2:-}"
    [[ -n "$iface" && -n "$want_mac" ]] || return 1

    local rule_file="${NIC_UDEV_RULE_FILE}"
    [[ -f "$rule_file" ]] || return 1

    local want_mac_lc="${want_mac,,}"
    local line line_lc
    while IFS= read -r line; do
        # Skip blank/comment lines.
        case "${line## }" in
            ''|'#'*) continue ;;
        esac
        line_lc="${line,,}"
        if [[ "$line_lc" == *"attr{address}==\"$want_mac_lc\""* \
           && "$line_lc" == *"name=\"${iface,,}\""* ]]; then
            return 0
        fi
    done < "$rule_file"
    return 1
}

# ---- nic_write_udev_rule <iface> <mac> -------------------------------------
#
# Idempotently install a rule that binds <iface> -> <mac> in
# NIC_UDEV_RULE_FILE. Other rules in the file are preserved verbatim;
# only previous rules that named <iface> (regardless of MAC) or that
# bound <mac> (regardless of name) are rewritten — this is what makes
# the function safe to call when the file already contains a stale
# entry from a prior run that targeted a different NIC or different
# ifname.
#
# Returns 0 on success, 1 on failure.
nic_write_udev_rule() {
    local iface="${1:-}"
    local mac="${2:-}"
    if [[ -z "$iface" || -z "$mac" ]]; then
        echo "nic_write_udev_rule: requires <iface> <mac>" >&2
        return 1
    fi
    if ! nic_validate_iface_name "$iface"; then
        echo "nic_write_udev_rule: invalid iface name: $iface" >&2
        return 1
    fi

    local rule_file="${NIC_UDEV_RULE_FILE}"
    local rule_dir
    rule_dir=$(dirname "$rule_file")
    if [[ ! -d "$rule_dir" ]]; then
        if ! $NIC_SUDO mkdir -p "$rule_dir"; then
            echo "nic_write_udev_rule: failed to create $rule_dir" >&2
            return 1
        fi
    fi

    local mac_lc="${mac,,}"
    local iface_lc="${iface,,}"
    local new_rule
    new_rule="SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"$mac_lc\", NAME=\"$iface\", RUN+=\"/sbin/ip link set $iface up\""

    # Read existing file (if any), filter out conflicting lines, append
    # the canonical rule. We keep comments and unrelated rules verbatim.
    local tmp
    tmp=$(mktemp 2>/dev/null) || {
        echo "nic_write_udev_rule: mktemp failed" >&2
        return 1
    }

    if [[ -f "$rule_file" ]]; then
        local line line_lc keep
        while IFS= read -r line || [[ -n "$line" ]]; do
            keep=1
            case "${line## }" in
                ''|'#'*)
                    : ;;
                *)
                    line_lc="${line,,}"
                    # Drop any rule that targets our iface name OR our
                    # MAC, so we replace stale bindings cleanly without
                    # disturbing rules for other NICs.
                    if [[ "$line_lc" == *"name=\"${iface_lc}\""* ]] \
                       || [[ "$line_lc" == *"attr{address}==\"${mac_lc}\""* ]]; then
                        keep=0
                    fi
                    ;;
            esac
            (( keep )) && printf '%s\n' "$line" >> "$tmp"
        done < "$rule_file"
    else
        printf '# EtherCAT NIC udev rules. Managed by setup_ethercat_interface.sh.\n' >> "$tmp"
    fi

    printf '%s\n' "$new_rule" >> "$tmp"

    if ! $NIC_SUDO install -m 0644 "$tmp" "$rule_file"; then
        rm -f "$tmp"
        echo "nic_write_udev_rule: failed to install $rule_file" >&2
        return 1
    fi
    rm -f "$tmp"
    return 0
}

# ---- nic_apply_udev <iface> ------------------------------------------------
#
# Reload udev rules, trigger a re-evaluation, then poll up to 10s for
# `ip link show <iface>` to succeed. Returns 0 once the iface is
# visible, 1 on timeout. Errors from udevadm itself surface as a
# non-zero return.
#
# Note: udev does not rename interfaces that are already up — for a
# brand-new NIC this works because the kernel hot-plugs and the rule
# fires; for an existing wrong-named iface, the caller must rename
# explicitly via `ip link set <old> name <iface>` (the CLI wrapper
# does this).
nic_apply_udev() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || {
        echo "nic_apply_udev: missing iface" >&2
        return 1
    }

    if ! $NIC_SUDO udevadm control --reload-rules; then
        echo "nic_apply_udev: udevadm control --reload-rules failed" >&2
        return 1
    fi
    # --action=change is best-effort; failure here is non-fatal because
    # the kernel may have already enumerated the device.
    $NIC_SUDO udevadm trigger --subsystem-match=net --action=change >/dev/null 2>&1 || true

    local i
    for ((i = 0; i < 20; i++)); do
        if ip link show "$iface" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "nic_apply_udev: timed out waiting for $iface" >&2
    return 1
}

# nic_apply_iface <iface> <mac>
#
# Higher-level apply: ensure the iface named <iface> exists and has
# MAC <mac>. Three cases handled:
#
#   1. an iface with <mac> is already named <iface> — return 0
#      (caller should also have checked nic_udev_rule_present for
#      reboot persistence)
#   2. an iface with <mac> exists under a different name — rename it
#      in-kernel via `ip link set <old> down; set name <iface>; set up`
#      (udev rules rename only on hotplug add, not on `udevadm trigger
#      --action=change`, so a manual rename is required for the live
#      kernel to pick up our rule's intent)
#   3. no iface currently presents <mac> — reload+trigger udev and
#      wait up to 10s for the kernel to hotplug + rename
#
# Returns 0 once the iface is present and named correctly, 1 on
# timeout / rename failure / missing args.
nic_apply_iface() {
    local iface="${1:-}" mac="${2:-}"
    if [[ -z "$iface" || -z "$mac" ]]; then
        echo "nic_apply_iface: usage: nic_apply_iface <iface> <mac>" >&2
        return 1
    fi
    mac="${mac,,}"

    # Case 1: already correctly named.
    if nic_already_named "$iface" "$mac"; then
        return 0
    fi

    # Case 2: iface with this MAC exists under a different name.
    local current
    current="$(nic_match_by_mac "$mac" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$iface" ]]; then
        # Reload rules first so the rename's eventual `ip link up`
        # doesn't lose any operator-managed flags. Best-effort.
        $NIC_SUDO udevadm control --reload-rules >/dev/null 2>&1 || true
        if ! $NIC_SUDO ip link set "$current" down; then
            echo "nic_apply_iface: failed to bring $current down" >&2
            return 1
        fi
        if ! $NIC_SUDO ip link set "$current" name "$iface"; then
            echo "nic_apply_iface: failed to rename $current -> $iface" >&2
            return 1
        fi
        $NIC_SUDO ip link set "$iface" up >/dev/null 2>&1 || true
        return 0
    fi

    # Case 3: no iface currently presents this MAC. Hotplug-wait.
    nic_apply_udev "$iface"
}
