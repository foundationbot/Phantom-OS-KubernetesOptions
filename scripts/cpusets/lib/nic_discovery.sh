#!/bin/bash
# lib/nic_discovery.sh — pure-shell NIC discovery and selector helpers.
#
# Sourceable library. Functions only. No top-level execution. No globals.
#
# Consumers:
#   - setup_ethercat_interface.sh (selector logic for non-interactive mode)
#
# Provides selector helpers that resolve a hardware identifier (MAC, PCI BDF,
# or driver+index) to a current Linux interface name on the host. These are
# used by the bootstrap path so a brand-new robot can be brought from
# "factory NIC" to a named ecatN interface non-interactively.

[[ -n "${__NIC_DISCOVERY_SH_SOURCED:-}" ]] && return 0
__NIC_DISCOVERY_SH_SOURCED=1

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "nic_discovery.sh requires bash." >&2
    return 1 2>/dev/null || exit 1
fi

# ---- nic_discover_all ------------------------------------------------------
# Echoes one NIC per line, tab-separated:
#   <ifname>\t<mac>\t<pci_bdf>\t<driver>
#
# pci_bdf is empty for non-PCI NICs (e.g. USB Ethernet).
# driver is the kernel module name resolved from /sys/.../device/driver.
#
# Skips lo, docker*, veth*, tailscale*, br-*, l4tbr*, wireless interfaces,
# and anything without a /device symlink (i.e. virtual).
nic_discover_all() {
    local iface_path iface_name device_path driver_path driver mac bdf
    for iface_path in /sys/class/net/*; do
        [[ -e "$iface_path" ]] || continue
        iface_name=$(basename "$iface_path")

        case "$iface_name" in
            lo|docker*|veth*|tailscale*|br-*|l4tbr*|cni*|flannel*|kube-*) continue ;;
        esac

        [[ ! -e "$iface_path/device" ]] && continue
        [[ -d "$iface_path/wireless" ]] && continue

        mac=$(cat "$iface_path/address" 2>/dev/null || echo "")
        # Skip all-zero or empty MACs (rare; typically virtual).
        [[ -z "$mac" || "$mac" == "00:00:00:00:00:00" ]] && continue

        device_path=$(readlink -f "$iface_path/device" 2>/dev/null || echo "")
        driver_path=$(readlink -f "$iface_path/device/driver" 2>/dev/null || echo "")
        if [[ -n "$driver_path" ]]; then
            driver=$(basename "$driver_path")
        else
            driver=""
        fi

        # Resolve PCI BDF (e.g. 0000:01:00.0) when the device is on the PCI bus.
        # /sys/class/net/<if>/device is itself a symlink to the PCI device dir
        # whose basename is the BDF. For non-PCI devices (USB), leave empty.
        bdf=""
        if [[ -n "$device_path" && "$device_path" == */pci* ]]; then
            local candidate
            candidate=$(basename "$device_path")
            # Match dddd:bb:dd.f
            if [[ "$candidate" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]+$ ]]; then
                bdf="$candidate"
            fi
        fi

        printf '%s\t%s\t%s\t%s\n' "$iface_name" "${mac,,}" "$bdf" "$driver"
    done
}

# ---- nic_match_by_mac <mac> ------------------------------------------------
# Echoes the matching NIC's current ifname. Exit 1 if none or >1.
nic_match_by_mac() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "nic_match_by_mac: missing MAC argument" >&2
        return 2
    fi
    target="${target,,}"

    local matches=""
    local ifname mac bdf drv
    while IFS=$'\t' read -r ifname mac bdf drv; do
        [[ -z "$ifname" ]] && continue
        if [[ "$mac" == "$target" ]]; then
            matches+="$ifname"$'\n'
        fi
    done < <(nic_discover_all)

    local count
    count=$(printf '%s' "$matches" | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
        echo "nic_match_by_mac: no NIC with MAC $target" >&2
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        echo "nic_match_by_mac: multiple NICs match MAC $target" >&2
        return 1
    fi
    printf '%s\n' "${matches%$'\n'}"
}

# ---- nic_match_by_pci <bdf> ------------------------------------------------
# Echoes matching NIC's ifname. BDF is matched case-insensitively. Exit 1 if
# none or >1.
nic_match_by_pci() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "nic_match_by_pci: missing PCI BDF argument" >&2
        return 2
    fi
    target="${target,,}"

    local matches=""
    local ifname mac bdf drv
    while IFS=$'\t' read -r ifname mac bdf drv; do
        [[ -z "$ifname" ]] && continue
        if [[ "${bdf,,}" == "$target" ]]; then
            matches+="$ifname"$'\n'
        fi
    done < <(nic_discover_all)

    local count
    count=$(printf '%s' "$matches" | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
        echo "nic_match_by_pci: no NIC with PCI BDF $target" >&2
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        echo "nic_match_by_pci: multiple NICs match PCI BDF $target" >&2
        return 1
    fi
    printf '%s\n' "${matches%$'\n'}"
}

# ---- nic_match_by_driver <drv> <index> -------------------------------------
# Among NICs bound to <driver>, sort by PCI BDF (with empty BDF sorting last
# so on-board PCI cards rank before USB), and echo the ifname at zero-based
# <index>. Exit 1 on out-of-range or no match.
nic_match_by_driver() {
    local target_drv="${1:-}"
    local target_idx="${2:-}"
    if [[ -z "$target_drv" || -z "$target_idx" ]]; then
        echo "nic_match_by_driver: requires <driver> <index>" >&2
        return 2
    fi
    if [[ ! "$target_idx" =~ ^[0-9]+$ ]]; then
        echo "nic_match_by_driver: index must be a non-negative integer (got: $target_idx)" >&2
        return 2
    fi

    # Collect candidates, then sort by BDF.
    local rows=""
    local ifname mac bdf drv sort_key
    while IFS=$'\t' read -r ifname mac bdf drv; do
        [[ -z "$ifname" ]] && continue
        if [[ "$drv" == "$target_drv" ]]; then
            # Sort key: empty BDF -> "zzzz..." so PCI cards come first.
            if [[ -n "$bdf" ]]; then
                sort_key="$bdf"
            else
                sort_key="zzzz:zz:zz.z"
            fi
            rows+="${sort_key}|${ifname}"$'\n'
        fi
    done < <(nic_discover_all)

    if [[ -z "$rows" ]]; then
        echo "nic_match_by_driver: no NICs bound to driver $target_drv" >&2
        return 1
    fi

    local sorted picked
    sorted=$(printf '%s' "$rows" | sort)
    local total
    total=$(printf '%s\n' "$sorted" | grep -c . || true)
    if (( target_idx >= total )); then
        echo "nic_match_by_driver: index $target_idx out of range (driver $target_drv has $total NIC(s))" >&2
        return 1
    fi
    picked=$(printf '%s\n' "$sorted" | sed -n "$((target_idx + 1))p")
    printf '%s\n' "${picked#*|}"
}

# ---- nic_validate_iface_name <name> ----------------------------------------
# Returns 0 if <name> is a valid kernel network interface name:
#   * 1..15 characters
#   * alphanumeric, underscore, dash, colon, dot
#   * cannot be empty, ".", or ".."
nic_validate_iface_name() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        return 1
    fi
    if [[ ${#name} -gt 15 ]]; then
        return 1
    fi
    if [[ "$name" == "." || "$name" == ".." ]]; then
        return 1
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9_:.-]+$ ]]; then
        return 1
    fi
    return 0
}

# ---- nic_iface_looks_default <name> ----------------------------------------
# Returns 0 if <name> looks like a kernel/udev *default* NIC name
# (eth*, en* — incl. eno/ens/enp/enx/enP — wl*, ww*, usb*, mgbe*, igb*,
# igc*, em*) rather than a deliberate EtherCAT name (the ecatN convention).
#
# Advisory predicate only — it does not reject anything. Binding the
# EtherCAT iface to a NIC's own default name is almost always a
# misconfiguration: the udev "rename" is a no-op, and the consumer
# (dma-ethercat.env INTERFACE=ecatN) never finds the interface. Callers
# warn on a match so the operator notices before shipping the config.
nic_iface_looks_default() {
    local name="${1:-}"
    [[ "$name" =~ ^(en|eth|wl|ww|usb|mgbe|igb|igc|em)[0-9a-zA-Z] ]]
}
