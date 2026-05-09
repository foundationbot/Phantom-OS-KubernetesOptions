#!/bin/bash
#
# setup_ethercat_interface.sh — thin CLI wrapper around lib/nic_setup.sh.
#
# Vendored and adapted from DMA.ethercat
# (scripts/setup_ethercat_interface.sh, SHA fd854dabcbbaba864a16c9e42fda98dfe386ab6a).
#
# All NIC selection / udev rule / rename logic lives in
#   - lib/nic_discovery.sh   (selector resolution)
#   - lib/nic_setup.sh       (rule writing, idempotency predicates,
#                             udev apply, interactive picker)
# This script is just argv parsing and a top-level state machine that
# composes those library functions. Bootstrap phase 7 sources nic_setup.sh
# directly and drives the same workflow without spawning this script.
#
# Local divergence vs upstream:
#   - Adds non-interactive selector mode (--mac / --pci / --driver+--index).
#   - Supports any kernel iface name via --iface (default ecat0).
#   - Idempotent: re-runs are no-ops when the iface already names the
#     desired MAC and the udev rule is already in place.
#   - Writes /etc/udev/rules.d/70-ecat.rules (vs upstream 99-ethercat.rules);
#     the 70- prefix orders the rule before systemd's net.link rules at 80-.
#   - Preserves unrelated rules in the file (nic_write_udev_rule rewrites
#     only the lines that bind to our target iface or MAC).
#   - set -u, no -e; explicit error handling, matching manage_cpusets.sh.
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

set -u  # explicit error handling via die(); no -e (matches manage_cpusets.sh)

# TUI bridge — op_confirm helper. Sourced when present; else a local
# fallback keeps the .deb-installed copy working.
_OPS_PROMPT="${BASH_SOURCE[0]%/*}/../lib/ops-prompt.sh"
if [ -r "$_OPS_PROMPT" ]; then
  # shellcheck disable=SC1090
  . "$_OPS_PROMPT"
else
  op_confirm() {
    local prompt="$1" default="${2:-false}" hint reply
    [ "$default" = true ] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$prompt $hint: " reply || return 1
    if [ -z "$reply" ]; then
      [ "$default" = true ] && return 0 || return 1
    fi
    case "$reply" in y|Y|yes|true) return 0 ;; *) return 1 ;; esac
  }
fi
unset _OPS_PROMPT

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

# Honoured by lib/nic_setup.sh.
export NIC_UDEV_RULE_FILE="$UDEV_RULE_FILE"

# ---------- Sudo -----------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi
export NIC_SUDO="$SUDO"

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}$*${NC}" >&2; }

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
# shellcheck source=./lib/nic_setup.sh
source "$LIB_DIR/nic_setup.sh"

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
  Interactive (no selector flags, stdin is a TTY): list adapters, prompt
  for selection, write udev rule, optionally configure RT pinning.

  Non-interactive: pass --iface <name> plus exactly one of --mac, --pci,
  or (--driver + --index). --yes is required to skip confirmation.

Selector flags (non-interactive):
  --iface <name>      Target interface name (default ecat0)
  --mac <addr>        Select adapter by MAC address (case-insensitive)
  --pci <BDF>         Select adapter by PCI BDF (e.g. 0000:01:00.0)
  --driver <name>     Select adapter by kernel driver (use with --index)
  --index <N>         Zero-based index within driver-matched set
  --yes               Skip confirmation prompts

Existing operator subcommands (preserved from upstream):
  --list, -l          List available Ethernet adapters
  --remove, -r        Remove the udev rule
  --rt-setup, -rt     Configure RT IRQ/core pinning only
  --rt-remove         Remove RT pinning systemd service
  --nic-tune          Apply ethtool NIC tuning
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

# ---------- Helpers (RT subcommand orchestration, unchanged) --------------
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

# Selector validation. Sets global SELECTOR_KIND to one of
# "mac" / "pci" / "driver" / "" (empty when no flags supplied). Calls
# die() on conflicting flags. Run BEFORE any subshell capture so die()
# actually terminates the script.
SELECTOR_KIND=""
validate_selector() {
    local count=0
    [[ -n "$OPT_MAC" ]]    && ((count++))
    [[ -n "$OPT_PCI" ]]    && ((count++))
    [[ -n "$OPT_DRIVER" ]] && ((count++))

    if (( count == 0 )); then
        SELECTOR_KIND=""
        return 0
    fi
    if (( count > 1 )); then
        die "exactly one of --mac, --pci, or --driver may be supplied (got $count)"
    fi
    if [[ -n "$OPT_DRIVER" ]]; then
        [[ -n "$OPT_INDEX" ]] || die "--driver requires --index"
        SELECTOR_KIND=driver
    elif [[ -n "$OPT_MAC" ]]; then
        [[ -z "$OPT_INDEX" ]] || die "--index is only valid with --driver"
        SELECTOR_KIND=mac
    else
        [[ -z "$OPT_INDEX" ]] || die "--index is only valid with --driver"
        SELECTOR_KIND=pci
    fi
}

# Resolve the selector to a target MAC. Echoes MAC on stdout.
resolve_selector_mac() {
    local kind="$1"
    case "$kind" in
        mac)    nic_resolve_target_mac --mac    "$OPT_MAC" ;;
        pci)    nic_resolve_target_mac --pci    "$OPT_PCI" ;;
        driver) nic_resolve_target_mac --driver "$OPT_DRIVER" --index "$OPT_INDEX" ;;
        *)      return 1 ;;
    esac
}

# Drive the named-iface workflow given the target MAC. Honors the
# idempotency invariant: short-circuits when iface+rule already match.
apply_named_iface() {
    local iface="$1"
    local mac="$2"

    nic_validate_iface_name "$iface" || die "invalid iface name: $iface"

    local need_rule=1 need_apply=1
    if nic_already_named "$iface" "$mac"; then
        need_apply=0
    fi
    if nic_udev_rule_present "$iface" "$mac"; then
        need_rule=0
    fi

    if (( need_rule == 0 && need_apply == 0 )); then
        echo -e "${GREEN}$iface already exists and udev rule is in place — nothing to do.${NC}"
        return 0
    fi

    if (( need_rule )); then
        echo -e "${BLUE}Writing udev rule for $iface -> $mac in $UDEV_RULE_FILE${NC}"
        nic_write_udev_rule "$iface" "$mac" || die "failed to write udev rule"
    fi

    if (( need_apply )); then
        # If an iface with the requested MAC exists under a different
        # name, rename it online so we don't have to wait for hotplug.
        local current_iface=""
        current_iface=$(nic_match_by_mac "$mac" 2>/dev/null || true)

        # Reload rules so the kernel picks them up for future hotplugs.
        nic_apply_udev "${current_iface:-$iface}" >/dev/null 2>&1 || true

        if [[ -n "$current_iface" && "$current_iface" != "$iface" ]]; then
            echo "Renaming $current_iface -> $iface online..."
            $SUDO ip link set "$current_iface" down || die "failed to bring $current_iface down"
            $SUDO ip link set "$current_iface" name "$iface" \
                || die "failed to rename $current_iface to $iface"
            $SUDO ip link set "$iface" up || warn "failed to bring $iface up"
        elif ! ip link show "$iface" >/dev/null 2>&1; then
            # No NIC currently presents this MAC — fall back to
            # waiting on udev to hotplug it.
            nic_apply_udev "$iface" || die "iface $iface did not appear after udev apply"
        fi
    fi

    echo ""
    echo -e "${GREEN}$iface configured.${NC}"
    echo "Persistence: $UDEV_RULE_FILE (applies on next boot too)."
}

# ---------- Main flow ------------------------------------------------------
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  EtherCAT Interface Setup           ${NC}"
echo -e "${BLUE}======================================${NC}"

# Subcommand dispatch (short-circuits before selector / interactive logic).
if $RT_REMOVE;       then remove_rt_setup; exit 0; fi
if $REMOVE_RULE;     then remove_udev_rule "$UDEV_RULE_FILE"; exit 0; fi
if $RT_SETUP_ONLY;   then run_rt_setup "${OPT_IFACE:-ecat0}"; exit $?; fi
if $NIC_TUNE_ONLY;   then
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
validate_selector
TARGET_IFACE="${OPT_IFACE:-ecat0}"

if [[ -n "$SELECTOR_KIND" ]]; then
    nic_validate_iface_name "$TARGET_IFACE" || die "invalid --iface: $TARGET_IFACE"
    target_mac=$(resolve_selector_mac "$SELECTOR_KIND") \
        || die "could not resolve selector to a NIC"

    if [[ "$ASSUME_YES" != true ]]; then
        if [[ ! -t 0 ]] && [[ "${_OPS_TUI:-0}" != 1 ]]; then
            die "non-interactive mode requires --yes when stdin is not a TTY"
        fi
        echo "About to bind iface $TARGET_IFACE to MAC $target_mac"
        echo "  udev rule: $UDEV_RULE_FILE"
        if ! op_confirm "Proceed?" false; then die "aborted by operator"; fi
    fi

    apply_named_iface "$TARGET_IFACE" "$target_mac"
    exit 0
fi

# ---------- No selectors: interactive or hard-fail ------------------------
if [[ ! -t 0 ]] && [[ "${_OPS_TUI:-0}" != 1 ]]; then
    die "no selector flags supplied and stdin is not a TTY. Pass --mac, --pci, or --driver+--index, or run from a terminal."
fi

if $LIST_ONLY; then
    find_usb_ethernet
    find_native_ethernet
    display_all_adapters
    exit 0
fi

nic_validate_iface_name "$TARGET_IFACE" || die "invalid --iface: $TARGET_IFACE"

# Existing-rule-file prompt (preserves upstream UX).
if [[ -f "$UDEV_RULE_FILE" ]]; then
    echo ""
    echo -e "${YELLOW}Existing udev rule file:${NC}"
    cat "$UDEV_RULE_FILE"
    echo ""
    if [[ "$ASSUME_YES" == true ]]; then
        replace_rule=true
    elif op_confirm "Add/replace the rule for $TARGET_IFACE?" false; then
        replace_rule=true
    else
        replace_rule=false
    fi
    if [[ "$replace_rule" != true ]]; then
        echo "Keeping existing rule."
        if ip link show "$TARGET_IFACE" &>/dev/null; then
            if op_confirm "Configure IRQ and CPU core pinning for real-time?" true; then
                run_rt_setup "$TARGET_IFACE"
            fi
        fi
        exit 0
    fi
fi

# Drive the picker via the library; it echoes the chosen MAC.
target_mac=$(nic_resolve_target_mac_interactive "$TARGET_IFACE") \
    || die "no adapter selected"
apply_named_iface "$TARGET_IFACE" "$target_mac"

if op_confirm "Configure IRQ and CPU core pinning for real-time?" true; then
    run_rt_setup "$TARGET_IFACE"
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
