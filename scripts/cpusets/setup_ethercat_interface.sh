#!/bin/bash
#
# setup_ethercat_interface.sh — Configure an Ethernet adapter for EtherCAT.
#
# Vendored and adapted from DMA.ethercat
# (scripts/setup_ethercat_interface.sh, SHA fd854dabcbbaba864a16c9e42fda98dfe386ab6a).
#
# Local divergence vs upstream:
#   - Adds a non-interactive selector path driven by --iface plus exactly one
#     of --mac, --pci, or --driver+--index. This is what the bootstrap phase
#     uses to bring a brand-new robot from "factory NIC" to "named ecatN"
#     without operator input.
#   - The upstream script is hardcoded to ecat0; this version supports any
#     valid kernel iface name via --iface (default ecat0 for the interactive
#     path, preserving upstream behaviour).
#   - Idempotent on re-run: if `ip link show <iface>` succeeds AND the udev
#     rule already names that NIC, the script exits 0 without rewriting.
#   - Writes /etc/udev/rules.d/70-ecat.rules instead of upstream's
#     /etc/udev/rules.d/99-ethercat.rules. The 70- prefix orders the rule
#     before systemd's net.link rules at 80- and the persistent-net rules
#     typically deployed at 75-/76- so the rename wins deterministically.
#   - set -u (no -e); explicit error handling via die(), matching the
#     manage_cpusets.sh convention in this directory.
#
# Usage:
#   Interactive (TTY):
#     ./setup_ethercat_interface.sh                 # legacy interactive flow
#     ./setup_ethercat_interface.sh --list
#     ./setup_ethercat_interface.sh --remove
#
#   Non-interactive (bootstrap):
#     ./setup_ethercat_interface.sh --iface ecat0 --mac aa:bb:cc:dd:ee:ff --yes
#     ./setup_ethercat_interface.sh --iface ecat1 --pci 0000:01:00.0 --yes
#     ./setup_ethercat_interface.sh --iface ecat0 --driver igc --index 0 --yes
#
# Selector precedence: exactly one of --mac, --pci, or (--driver + --index)
# must be supplied in non-interactive mode. They are mutually exclusive. The
# script fails fast if zero or multiple selectors are provided.

set -u  # explicit error handling via die(); no -e (matches manage_cpusets.sh)

# ---------- Colors ---------------------------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# ---------- Paths ----------------------------------------------------------
# Local divergence: 70-ecat.rules (vs upstream 99-ethercat.rules). See header.
UDEV_RULE_FILE="/etc/udev/rules.d/70-ecat.rules"
SERVICE_FILE="/etc/systemd/system/ethercat-irq-affinity.service"
IRQ_SCRIPT_FILE="/usr/local/bin/ethercat-irq-affinity.sh"
IRQBALANCE_CONF="/etc/default/irqbalance"
TUNING_DISPATCHER_DIR="/etc/networkd-dispatcher/routable.d"
# TUNING_DISPATCHER_FILE is computed per-iface inside run_rt_setup.

# ---------- Sudo -----------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

die() {
    echo -e "${RED}ERROR: $*${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}$*${NC}" >&2
}

# ---------- Source libraries ----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
[[ -d "$LIB_DIR" ]] || die "library directory not found: $LIB_DIR"

# shellcheck source=./lib/cpu_utils.sh
source "$LIB_DIR/cpu_utils.sh"
# shellcheck source=./lib/nic_rt.sh
source "$LIB_DIR/nic_rt.sh"
# shellcheck source=./lib/systemd_units.sh
source "$LIB_DIR/systemd_units.sh"
# shellcheck source=./lib/nic_discovery.sh
source "$LIB_DIR/nic_discovery.sh"

# ---------- Argument parsing -----------------------------------------------
LIST_ONLY=false
REMOVE_RULE=false
RT_SETUP_ONLY=false
RT_REMOVE=false
NIC_TUNE_ONLY=false
NIC_TUNE_REMOVE=false
ASSUME_YES=false

OPT_IFACE=""
OPT_MAC=""
OPT_PCI=""
OPT_DRIVER=""
OPT_INDEX=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Modes:
  Interactive (no selector flags, stdin is a TTY): the original DMA.ethercat
  flow — list adapters, prompt for selection, write udev rule, optionally
  configure RT pinning.

  Non-interactive: pass --iface <name> plus exactly one of --mac, --pci, or
  (--driver + --index). --yes is required to skip confirmation.

Selector flags (non-interactive):
  --iface <name>      Target interface name (default ecat0)
  --mac <addr>        Select adapter by MAC address (case-insensitive)
  --pci <BDF>         Select adapter by PCI BDF (e.g. 0000:01:00.0)
  --driver <name>     Select adapter by kernel driver (use with --index)
  --index <N>         Zero-based index within driver-matched set, sorted by PCI BDF
  --yes               Skip confirmation prompts

Existing operator subcommands (preserved from upstream):
  --list, -l          List available Ethernet adapters
  --remove, -r        Remove the udev rule
  --rt-setup, -rt     Configure RT IRQ/core pinning only (iface must exist)
  --rt-remove         Remove RT pinning systemd service
  --nic-tune          Apply ethtool NIC tuning for low-latency EtherCAT
  --nic-tune-remove   Remove persistent NIC tuning dispatcher script
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list|-l)            LIST_ONLY=true ; shift ;;
        --remove|-r)          REMOVE_RULE=true ; shift ;;
        --rt-setup|-rt)       RT_SETUP_ONLY=true ; shift ;;
        --rt-remove)          RT_REMOVE=true ; shift ;;
        --nic-tune)           NIC_TUNE_ONLY=true ; shift ;;
        --nic-tune-remove)    NIC_TUNE_REMOVE=true ; shift ;;
        --yes|-y)             ASSUME_YES=true ; shift ;;
        --iface)              OPT_IFACE="${2:-}" ; shift 2 ;;
        --mac)                OPT_MAC="${2:-}" ; shift 2 ;;
        --pci)                OPT_PCI="${2:-}" ; shift 2 ;;
        --driver)             OPT_DRIVER="${2:-}" ; shift 2 ;;
        --index)              OPT_INDEX="${2:-}" ; shift 2 ;;
        -h|--help)            usage ; exit 0 ;;
        *)                    echo "Unknown option: $1" >&2 ; usage >&2 ; exit 1 ;;
    esac
done

# ---------- Helpers --------------------------------------------------------

# Returns 0 if the given udev rule file already exists AND already names the
# NIC currently visible as $iface (i.e. matches its MAC). Used for idempotent
# early-exit when the host has already been configured.
udev_rule_already_targets() {
    local iface="$1"
    local rule_file="$2"

    [[ -f "$rule_file" ]] || return 1

    local current_mac
    current_mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "")
    [[ -n "$current_mac" ]] || return 1

    if grep -Fq "NAME=\"$iface\"" "$rule_file" 2>/dev/null && \
       grep -iFq "$current_mac" "$rule_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Resolves the requested selector to a current ifname; sets RESOLVED_IFACE.
# Returns 1 if no selector flags supplied (caller falls back to interactive).
# Calls die() on conflicting / malformed selectors.
resolve_selector() {
    local count=0
    [[ -n "$OPT_MAC" ]]    && ((count++))
    [[ -n "$OPT_PCI" ]]    && ((count++))
    [[ -n "$OPT_DRIVER" ]] && ((count++))

    if (( count == 0 )); then
        return 1
    fi
    if (( count > 1 )); then
        die "exactly one of --mac, --pci, or --driver may be supplied (got $count)"
    fi

    if [[ -n "$OPT_DRIVER" ]]; then
        [[ -n "$OPT_INDEX" ]] || die "--driver requires --index"
        RESOLVED_IFACE=$(nic_match_by_driver "$OPT_DRIVER" "$OPT_INDEX") || \
            die "could not resolve --driver $OPT_DRIVER --index $OPT_INDEX to a NIC"
    elif [[ -n "$OPT_MAC" ]]; then
        [[ -z "$OPT_INDEX" ]] || die "--index is only valid with --driver"
        RESOLVED_IFACE=$(nic_match_by_mac "$OPT_MAC") || \
            die "could not resolve --mac $OPT_MAC to a NIC"
    elif [[ -n "$OPT_PCI" ]]; then
        [[ -z "$OPT_INDEX" ]] || die "--index is only valid with --driver"
        RESOLVED_IFACE=$(nic_match_by_pci "$OPT_PCI") || \
            die "could not resolve --pci $OPT_PCI to a NIC"
    fi
    return 0
}

# Non-interactive flow: write udev rule for $target_iface using current MAC of
# $current_iface, trigger udev, and (if not already named) rename online.
run_non_interactive() {
    local target_iface="$1"
    local current_iface="$2"

    nic_validate_iface_name "$target_iface" || \
        die "invalid kernel iface name: $target_iface"

    # Idempotent fast path.
    if ip link show "$target_iface" &>/dev/null && \
       udev_rule_already_targets "$target_iface" "$UDEV_RULE_FILE"; then
        echo -e "${GREEN}$target_iface already exists and udev rule is in place — nothing to do.${NC}"
        exit 0
    fi

    local current_mac driver description
    current_mac=$(cat "/sys/class/net/$current_iface/address" 2>/dev/null || echo "")
    [[ -n "$current_mac" ]] || die "could not read MAC for $current_iface"

    # Best-effort driver and description for the rule comment.
    driver=$(udevadm info -q property -p "/sys/class/net/$current_iface" 2>/dev/null | \
             grep "ID_NET_DRIVER=" | cut -d= -f2)
    [[ -z "$driver" ]] && driver=$(basename "$(readlink -f "/sys/class/net/$current_iface/device/driver")" 2>/dev/null || echo "unknown")
    description="non-interactive bootstrap (selector: ${OPT_MAC:+mac=$OPT_MAC }${OPT_PCI:+pci=$OPT_PCI }${OPT_DRIVER:+driver=$OPT_DRIVER index=$OPT_INDEX})"

    if [[ "$ASSUME_YES" != true ]]; then
        echo "About to rename $current_iface (MAC $current_mac) -> $target_iface"
        echo "  udev rule: $UDEV_RULE_FILE"
        if [[ ! -t 0 ]]; then
            die "non-interactive mode requires --yes when stdin is not a TTY"
        fi
        read -p "Proceed? [y/N] " -n 1 -r
        echo
        [[ "$REPLY" =~ ^[Yy]$ ]] || die "aborted by operator"
    fi

    create_udev_rule_mac "$current_mac" "$driver" "$description" \
        "$UDEV_RULE_FILE" "$target_iface"

    # Trigger udev to apply on currently-bound devices.
    $SUDO udevadm control --reload-rules
    $SUDO udevadm trigger --subsystem-match=net --action=change 2>/dev/null || true

    # If the kernel didn't rename via trigger (it usually doesn't for already-
    # present devices), do it explicitly.
    if ip link show "$target_iface" &>/dev/null; then
        echo -e "${GREEN}  $target_iface is up.${NC}"
    else
        echo "Renaming $current_iface -> $target_iface online..."
        $SUDO ip link set "$current_iface" down || die "failed to bring $current_iface down"
        $SUDO ip link set "$current_iface" name "$target_iface" || \
            die "failed to rename $current_iface to $target_iface"
        $SUDO ip link set "$target_iface" up || warn "failed to bring $target_iface up"
    fi

    echo ""
    echo -e "${GREEN}$target_iface configured.${NC}"
    echo "Persistence: $UDEV_RULE_FILE (applies on next boot too)."
}

# ---------- Higher-level orchestration -------------------------------------
# Carried across mostly verbatim from upstream so --rt-setup and the legacy
# interactive path keep working. Only the iface argument is now parameterised.
run_rt_setup() {
    local nic="${1:-ecat0}"
    local tuning_dispatcher_file="$TUNING_DISPATCHER_DIR/${nic}-tuning.sh"
    export TUNING_DISPATCHER_FILE="$tuning_dispatcher_file"

    echo ""
    echo -e "${BLUE}--------------------------------------${NC}"
    echo -e "${BLUE}  RT IRQ and Core Pinning Setup       ${NC}"
    echo -e "${BLUE}--------------------------------------${NC}"
    echo ""

    if ! ip link show "$nic" &>/dev/null; then
        echo -e "${RED}Interface $nic not found. Set up the interface first.${NC}"
        return 1
    fi

    if ! select_rt_core; then
        return 1
    fi

    echo ""

    local irqs
    irqs=$(find_nic_irqs "$nic")

    if [[ -z "$irqs" ]]; then
        echo -e "${RED}No IRQs found for $nic. Is the interface up?${NC}"
        return 1
    fi

    echo -e "${BLUE}Found IRQs for $nic: $irqs${NC}"
    echo ""

    # shellcheck disable=SC2086
    pin_irqs_to_core "$RT_CORE" $irqs
    echo ""
    # shellcheck disable=SC2086
    configure_irqbalance $irqs
    echo ""
    write_ethercat_rt_service "$nic" "$RT_CORE" "$SERVICE_FILE" "$IRQ_SCRIPT_FILE"
    echo ""
    apply_nic_tuning "$nic"
    echo ""
    create_nic_tuning_dispatcher "$nic"
    echo ""
    lock_isolated_core_governors
    echo ""
    restrict_workqueue_mask
    echo ""
    check_kernel_params "$RT_CORE"

    echo ""
    echo -e "${GREEN}  RT Setup Complete${NC}"
}

remove_rt_setup() {
    echo -e "${BLUE}Removing RT pinning setup...${NC}"
    remove_ethercat_rt_service "$SERVICE_FILE" "$IRQ_SCRIPT_FILE"

    if [[ -f "$IRQBALANCE_CONF" ]] && grep -q "^IRQBALANCE_BANNED_IRQS" "$IRQBALANCE_CONF" 2>/dev/null; then
        $SUDO sed -i '/^IRQBALANCE_BANNED_IRQS/d' "$IRQBALANCE_CONF"
        echo -e "${GREEN}  Cleaned irqbalance config${NC}"
        if systemctl is-active --quiet irqbalance 2>/dev/null; then
            $SUDO systemctl restart irqbalance
        fi
    fi

    remove_nic_tuning_dispatcher "${TUNING_DISPATCHER_FILE:-$TUNING_DISPATCHER_DIR/ecat0-tuning.sh}"
    echo -e "${GREEN}RT pinning setup removed.${NC}"
}

# ---------- Main flow ------------------------------------------------------
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  EtherCAT Interface Setup           ${NC}"
echo -e "${BLUE}======================================${NC}"

# Subcommand dispatch (these short-circuit before the selector / interactive
# logic, matching upstream behaviour).
if $RT_REMOVE; then
    remove_rt_setup
    exit 0
fi

if $REMOVE_RULE; then
    remove_udev_rule "$UDEV_RULE_FILE"
    exit 0
fi

if $RT_SETUP_ONLY; then
    run_rt_setup "${OPT_IFACE:-ecat0}"
    exit $?
fi

if $NIC_TUNE_ONLY; then
    iface="${OPT_IFACE:-ecat0}"
    apply_nic_tuning "$iface"
    echo ""
    create_nic_tuning_dispatcher "$iface"
    exit $?
fi

if $NIC_TUNE_REMOVE; then
    iface="${OPT_IFACE:-ecat0}"
    echo -e "${BLUE}Removing NIC tuning dispatcher script...${NC}"
    remove_nic_tuning_dispatcher "$TUNING_DISPATCHER_DIR/${iface}-tuning.sh"
    exit 0
fi

# ---------- Selector resolution (non-interactive path) --------------------
RESOLVED_IFACE=""
if resolve_selector; then
    target="${OPT_IFACE:-ecat0}"
    nic_validate_iface_name "$target" || die "invalid --iface: $target"
    echo "Selector resolved: $RESOLVED_IFACE -> $target"
    run_non_interactive "$target" "$RESOLVED_IFACE"
    exit 0
fi

# ---------- No selectors: interactive or hard-fail ------------------------
if [[ ! -t 0 ]]; then
    die "no selector flags supplied and stdin is not a TTY. Pass --mac, --pci, or --driver+--index, or run from a terminal."
fi

# Find all adapters for interactive mode (uses globals from nic_rt.sh).
find_usb_ethernet
find_native_ethernet

if $LIST_ONLY; then
    display_all_adapters
    exit 0
fi

# Interactive iface name (default ecat0, preserves upstream behaviour).
INTERACTIVE_IFACE="${OPT_IFACE:-ecat0}"
nic_validate_iface_name "$INTERACTIVE_IFACE" || die "invalid --iface: $INTERACTIVE_IFACE"

# Existing udev rule prompt.
if [[ -f "$UDEV_RULE_FILE" ]]; then
    echo ""
    echo -e "${YELLOW}Existing udev rule found:${NC}"
    cat "$UDEV_RULE_FILE"
    echo ""
    if [[ "$ASSUME_YES" == true ]]; then
        REPLY="y"
    else
        read -p "Do you want to replace it? [y/N] " -n 1 -r
        echo
    fi
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Keeping existing rule."
        if ip link show "$INTERACTIVE_IFACE" &>/dev/null; then
            echo ""
            read -p "Configure IRQ and CPU core pinning for real-time? [Y/n] " -n 1 -r
            echo
            if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
                run_rt_setup "$INTERACTIVE_IFACE"
            fi
        fi
        exit 0
    fi
fi

if ip link show "$INTERACTIVE_IFACE" &>/dev/null; then
    echo ""
    echo -e "${GREEN}  $INTERACTIVE_IFACE interface already exists${NC}"
    ip link show "$INTERACTIVE_IFACE"
    echo ""
    read -p "Do you want to reconfigure it? [y/N] " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo ""
        read -p "Configure IRQ and CPU core pinning for real-time? [Y/n] " -n 1 -r
        echo
        if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
            run_rt_setup "$INTERACTIVE_IFACE"
        fi
        exit 0
    fi
fi

if ! display_all_adapters; then
    echo ""
    echo "Make sure your Ethernet adapter is connected."
    echo "You can check with: lsusb (USB) or lspci (PCI)"
    exit 1
fi

total=$((${#USB_ADAPTERS[@]} + ${#NATIVE_ADAPTERS[@]}))

if [[ $total -eq 1 ]]; then
    selection=1
    echo "Only one adapter found, selecting it automatically."
else
    read -p "Select adapter to use for EtherCAT [1-$total]: " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt $total ]]; then
        die "Invalid selection."
    fi
fi

if [[ "$selection" -le ${#USB_ADAPTERS[@]} ]]; then
    selected="${USB_ADAPTERS[$((selection-1))]}"
    IFS='|' read -r iface vendor product driver manufacturer product_name mac <<< "$selected"

    echo ""
    echo -e "${BLUE}Selected: $iface ($manufacturer $product_name) [USB]${NC}"
    echo ""

    create_udev_rule_usb "$vendor" "$product" "$driver" \
        "$manufacturer $product_name" "$UDEV_RULE_FILE" "$INTERACTIVE_IFACE"
else
    native_idx=$((selection - ${#USB_ADAPTERS[@]} - 1))
    selected="${NATIVE_ADAPTERS[$native_idx]}"
    IFS='|' read -r iface driver mac bus_info description speed <<< "$selected"

    echo ""
    echo -e "${BLUE}Selected: $iface ($description, $driver) [NIC]${NC}"
    echo ""

    create_udev_rule_mac "$mac" "$driver" "$description" \
        "$UDEV_RULE_FILE" "$INTERACTIVE_IFACE"
fi

echo ""
read -p "Rename $iface to $INTERACTIVE_IFACE now? [Y/n] " -n 1 -r
echo
if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    echo "Renaming $iface -> $INTERACTIVE_IFACE..."
    $SUDO ip link set "$iface" down
    $SUDO ip link set "$iface" name "$INTERACTIVE_IFACE"
    $SUDO ip link set "$INTERACTIVE_IFACE" up

    sleep 1

    if ip link show "$INTERACTIVE_IFACE" &>/dev/null; then
        echo ""
        echo -e "${GREEN}  $INTERACTIVE_IFACE interface is now available!${NC}"
        ip link show "$INTERACTIVE_IFACE"
    else
        echo ""
        echo -e "${RED}  Rename failed.${NC}"
        echo "  The udev rule will apply the rename on next reboot."
    fi
else
    echo ""
    echo -e "${YELLOW}The udev rule will rename the interface on next reboot.${NC}"
fi

echo ""
read -p "Configure IRQ and CPU core pinning for real-time? [Y/n] " -n 1 -r
echo
if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    run_rt_setup "$INTERACTIVE_IFACE"
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
