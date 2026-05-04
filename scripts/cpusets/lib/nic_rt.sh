#!/bin/bash
# lib/nic_rt.sh — NIC detection, IRQ pinning, ethtool tuning, udev rules.
#
# Sourceable library. Functions only. No top-level execution.
# Consumers:
#   - setup_ethercat_interface.sh (interactive EtherCAT NIC setup)
#   - manage_cpusets.sh (ethercat-rt subcommand)
#
# Applies the following improvements over the original inline implementation:
#   * pin_irqs_to_core surfaces driver-managed IRQ failures with actionable text
#   * apply_nic_tuning comment matches what napi_defer_hard_irqs actually does
#   * select_rt_core prompts before continuing with a non-isolated core
#   * check_kernel_params accepts cpuset isolation as equivalent to isolcpus=
#   * check_kernel_params checks irqaffinity=
#   * new lock_isolated_core_governors pins performance governor on isolated cores
#   * new restrict_workqueue_mask steers unbound kworkers to housekeeping cores

[[ -n "${__NIC_RT_SH_SOURCED:-}" ]] && return 0
__NIC_RT_SH_SOURCED=1

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "nic_rt.sh requires bash." >&2
    return 1 2>/dev/null || exit 1
fi

# Pull in cpu_utils.sh from the same directory. BASH_SOURCE works across
# both direct-source and nested-source cases.
_nic_rt_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cpu_utils.sh
source "$_nic_rt_lib_dir/cpu_utils.sh"

# ---- Colors and sudo -------------------------------------------------------
# Only define if not already set by the sourcing script, so we don't clobber
# a CLI that has its own palette.
: "${RED:=$'\033[0;31m'}"
: "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${BLUE:=$'\033[0;34m'}"
: "${NC:=$'\033[0m'}"

if [[ -z "${SUDO+x}" ]]; then
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
fi

# ---- Adapter detection -----------------------------------------------------
# These populate global arrays because both the existing EtherCAT CLI and the
# new cpuset CLI want to display a unified list. Callers read the arrays
# after calling the find_* functions.
USB_ADAPTERS=()
NATIVE_ADAPTERS=()

find_usb_ethernet() {
    USB_ADAPTERS=()
    local iface iface_name device_path udev_info vendor product driver
    local product_name manufacturer mac

    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")

        [[ "$iface_name" == "lo" ]] && continue
        [[ "$iface_name" == docker* ]] && continue
        [[ "$iface_name" == tailscale* ]] && continue
        [[ "$iface_name" == veth* ]] && continue
        [[ "$iface_name" == l4tbr* ]] && continue
        [[ ! -d "$iface/device" ]] && continue

        device_path=$(readlink -f "$iface/device")
        if echo "$device_path" | grep -q "usb"; then
            udev_info=$(udevadm info -a -p "/sys/class/net/$iface_name" 2>/dev/null)

            vendor=$(echo "$udev_info" | grep 'ATTRS{idVendor}' | head -1 | sed 's/.*=="\([^"]*\)".*/\1/')
            product=$(echo "$udev_info" | grep 'ATTRS{idProduct}' | head -1 | sed 's/.*=="\([^"]*\)".*/\1/')
            driver=$(echo "$udev_info" | grep 'DRIVERS==' | grep -v '==""' | head -1 | sed 's/.*=="\([^"]*\)".*/\1/')

            product_name=$(udevadm info -q property -p "/sys/class/net/$iface_name" 2>/dev/null | grep "ID_MODEL=" | cut -d= -f2 | tr '_' ' ')
            manufacturer=$(udevadm info -q property -p "/sys/class/net/$iface_name" 2>/dev/null | grep "ID_VENDOR=" | cut -d= -f2 | tr '_' ' ')

            [[ -z "$product_name" ]] && product_name="USB Ethernet"
            [[ -z "$manufacturer" ]] && manufacturer="Unknown"

            mac=$(cat "$iface/address" 2>/dev/null || echo "Unknown")

            if [[ -n "$vendor" ]] && [[ -n "$product" ]]; then
                USB_ADAPTERS+=("$iface_name|$vendor|$product|$driver|$manufacturer|$product_name|$mac")
            fi
        fi
    done
}

find_native_ethernet() {
    NATIVE_ADAPTERS=()
    local iface iface_name device_path driver mac bus_info speed description

    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")

        [[ "$iface_name" == "lo" ]] && continue
        [[ "$iface_name" == docker* ]] && continue
        [[ "$iface_name" == tailscale* ]] && continue
        [[ "$iface_name" == veth* ]] && continue
        [[ "$iface_name" == l4tbr* ]] && continue
        [[ "$iface_name" == br-* ]] && continue
        [[ ! -d "$iface/device" ]] && continue
        [[ -d "$iface/wireless" ]] && continue

        device_path=$(readlink -f "$iface/device")
        if echo "$device_path" | grep -q "usb"; then
            continue
        fi

        driver=$(udevadm info -q property -p "/sys/class/net/$iface_name" 2>/dev/null | grep "ID_NET_DRIVER=" | cut -d= -f2)
        [[ -z "$driver" ]] && driver=$(basename "$(readlink -f "$iface/device/driver")" 2>/dev/null || echo "unknown")

        mac=$(cat "$iface/address" 2>/dev/null || echo "Unknown")

        bus_info=""
        if echo "$device_path" | grep -q "pci"; then
            bus_info=$(basename "$(readlink -f "$iface/device")" 2>/dev/null || echo "")
        fi

        speed=$(cat "$iface/speed" 2>/dev/null || echo "unknown")
        [[ "$speed" == "unknown" ]] || speed="${speed}Mbps"

        description="Native Ethernet"
        [[ -n "$bus_info" ]] && description="PCI $bus_info"

        NATIVE_ADAPTERS+=("$iface_name|$driver|$mac|$bus_info|$description|$speed")
    done
}

display_all_adapters() {
    local i=1 adapter iface vendor product driver manufacturer product_name mac
    local bus_info description speed

    if [[ ${#USB_ADAPTERS[@]} -eq 0 ]] && [[ ${#NATIVE_ADAPTERS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No Ethernet adapters found.${NC}"
        return 1
    fi

    echo ""
    echo -e "${BLUE}Found Ethernet adapters:${NC}"
    echo ""

    for adapter in "${USB_ADAPTERS[@]}"; do
        IFS='|' read -r iface vendor product driver manufacturer product_name mac <<< "$adapter"
        echo -e "  ${GREEN}[$i]${NC} $iface ${BLUE}[USB]${NC}"
        echo "      Vendor/Product: $vendor:$product"
        echo "      Driver: $driver"
        echo "      Description: $manufacturer $product_name"
        echo "      MAC: $mac"
        echo ""
        ((i++))
    done

    for adapter in "${NATIVE_ADAPTERS[@]}"; do
        IFS='|' read -r iface driver mac bus_info description speed <<< "$adapter"
        echo -e "  ${GREEN}[$i]${NC} $iface ${YELLOW}[NIC]${NC}"
        echo "      Driver: $driver"
        echo "      Description: $description"
        echo "      MAC: $mac"
        echo "      Speed: $speed"
        echo ""
        ((i++))
    done

    return 0
}

# ---- Udev rules ------------------------------------------------------------
reload_udev() {
    echo "Reloading udev rules..."
    $SUDO udevadm control --reload-rules
    echo -e "${GREEN}  Udev rules reloaded${NC}"
}

# Arguments: vendor, product, driver, description, rule_file, rename_to
create_udev_rule_usb() {
    local vendor="$1"
    local product="$2"
    local driver="$3"
    local description="$4"
    local rule_file="${5:-/etc/udev/rules.d/99-ethercat.rules}"
    local rename_to="${6:-ecat0}"

    echo -e "${BLUE}Creating udev rule (USB vendor:product match)...${NC}"

    local rule_content
    rule_content="# EtherCAT Ethernet adapter rule
# Device: $description
# Created by setup_ethercat_interface.sh on $(date)

# Rename USB Ethernet adapter to $rename_to and bring it up
SUBSYSTEM==\"net\", ACTION==\"add\", ATTRS{idVendor}==\"$vendor\", ATTRS{idProduct}==\"$product\", NAME=\"$rename_to\", RUN+=\"/sbin/ip link set $rename_to up\"

# Alternative rule using driver (backup if vendor/product doesn't match)
# SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"$driver\", NAME=\"$rename_to\", RUN+=\"/sbin/ip link set $rename_to up\"
"

    echo "$rule_content" | $SUDO tee "$rule_file" > /dev/null
    echo -e "${GREEN}  Created $rule_file${NC}"

    reload_udev
}

# Arguments: mac, driver, description, rule_file, rename_to
create_udev_rule_mac() {
    local mac="$1"
    local driver="$2"
    local description="$3"
    local rule_file="${4:-/etc/udev/rules.d/99-ethercat.rules}"
    local rename_to="${5:-ecat0}"

    echo -e "${BLUE}Creating udev rule (MAC address match)...${NC}"

    local rule_content
    rule_content="# EtherCAT Ethernet adapter rule
# Device: $description (driver: $driver)
# Created by setup_ethercat_interface.sh on $(date)

# Rename native Ethernet NIC to $rename_to and bring it up
SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"$mac\", NAME=\"$rename_to\", RUN+=\"/sbin/ip link set $rename_to up\"
"

    echo "$rule_content" | $SUDO tee "$rule_file" > /dev/null
    echo -e "${GREEN}  Created $rule_file${NC}"

    reload_udev
}

remove_udev_rule() {
    local rule_file="${1:-/etc/udev/rules.d/99-ethercat.rules}"
    if [[ -f "$rule_file" ]]; then
        echo -e "${BLUE}Removing udev rule...${NC}"
        $SUDO rm -f "$rule_file"
        $SUDO udevadm control --reload-rules
        echo -e "${GREEN}  Removed $rule_file${NC}"
        echo -e "${GREEN}  Udev rules reloaded${NC}"
    else
        echo -e "${YELLOW}No udev rule found at $rule_file${NC}"
    fi
}

# ---- IRQ discovery and pinning --------------------------------------------
find_nic_irqs() {
    local nic="$1"
    local all_irqs=""

    local irqs_proc
    irqs_proc=$(grep -E "$nic" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' || true)

    local irqs_sys=""
    if [[ -d "/sys/class/net/$nic/device/msi_irqs" ]]; then
        irqs_sys=$(ls "/sys/class/net/$nic/device/msi_irqs/" 2>/dev/null || true)
    fi

    local irq_single=""
    if [[ -f "/sys/class/net/$nic/device/irq" ]]; then
        irq_single=$(cat "/sys/class/net/$nic/device/irq" 2>/dev/null || true)
    fi

    all_irqs=$(echo "$irqs_proc $irqs_sys $irq_single" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

    echo "$all_irqs"
}

# Pin a whitespace-separated list of IRQs to a single CPU core.
# Arguments: core, irqs...
# Improved over the original: surfaces driver-managed IRQs with actionable
# text and checks whether the kernel actually accepted the requested affinity.
pin_irqs_to_core() {
    local core="$1"
    shift
    local irqs="$*"

    local cpu_mask
    cpu_mask=$(printf "%x" $((1 << core)))

    echo -e "${BLUE}Pinning IRQs to core $core (mask 0x$cpu_mask)...${NC}"

    local irq actual
    for irq in $irqs; do
        [[ -z "$irq" ]] && continue
        if [[ ! -f "/proc/irq/$irq/smp_affinity" ]]; then
            continue
        fi

        if ! $SUDO sh -c "echo $cpu_mask > /proc/irq/$irq/smp_affinity" 2>/dev/null; then
            echo -e "${YELLOW}  IRQ $irq: affinity write failed — likely driver-managed.${NC}"
            echo -e "${YELLOW}           Fix via driver module params or 'ethtool -L <iface> combined N'.${NC}"
            continue
        fi

        actual=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null)
        if [[ "$actual" != "$core" ]]; then
            echo -e "${YELLOW}  IRQ $irq: requested core $core, kernel set $actual (driver-managed).${NC}"
        else
            echo -e "${GREEN}  IRQ $irq -> core $actual${NC}"
        fi
    done
}

# Tell irqbalance to leave a given list of IRQs alone.
configure_irqbalance() {
    local irqs="$*"
    local conf="${IRQBALANCE_CONF:-/etc/default/irqbalance}"
    local banned
    banned=$(echo "$irqs" | tr ' ' ',')

    echo -e "${BLUE}Configuring irqbalance...${NC}"

    if [[ -f "$conf" ]]; then
        $SUDO cp "$conf" "${conf}.bak.$(date +%s)"
        $SUDO sed -i '/^IRQBALANCE_BANNED_IRQS/d' "$conf"
        echo "IRQBALANCE_BANNED_IRQS=\"$banned\"" | $SUDO tee -a "$conf" > /dev/null
        echo -e "${GREEN}  Added banned IRQs to $conf: $banned${NC}"

        if systemctl is-active --quiet irqbalance 2>/dev/null; then
            $SUDO systemctl restart irqbalance
            echo -e "${GREEN}  Restarted irqbalance${NC}"
        fi
    else
        echo -e "${YELLOW}  irqbalance config not found at $conf (skipped)${NC}"
    fi
}

# ---- NIC tuning (ethtool) --------------------------------------------------
# Low-latency settings for EtherCAT raw L2 traffic.
apply_nic_tuning() {
    local nic="${1:-ecat0}"

    if ! ip link show "$nic" &>/dev/null; then
        echo -e "${RED}Interface $nic not found.${NC}"
        return 1
    fi

    echo -e "${BLUE}Applying NIC tuning for EtherCAT on $nic...${NC}"

    # 1. Force 100 Mbps full-duplex, disable auto-negotiation. Autoneg flaps
    #    during operation are the root cause of EtherCAT frame-alignment errors.
    echo -n "  Speed/duplex  (100M full, autoneg off) ... "
    if $SUDO ethtool -s "$nic" speed 100 duplex full autoneg off 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}skipped (not supported by driver)${NC}"
    fi

    # 2. Disable interrupt coalescing for minimum latency.
    echo -n "  Coalescing    (rx-usecs 0, tx-usecs 0) ... "
    if $SUDO ethtool -C "$nic" rx-usecs 0 tx-usecs 0 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}skipped (not supported by driver)${NC}"
    fi

    # 3. Disable segmentation/aggregation offloads — EtherCAT is raw L2, not TCP.
    echo -n "  TCP offload   (tso/gso/gro/lro off)    ... "
    if $SUDO ethtool -K "$nic" tso off gso off gro off lro off 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}skipped (not supported by driver)${NC}"
    fi

    # 4. Small ring buffers to minimize queuing latency.
    echo -n "  Ring buffer   (rx 64, tx 64)            ... "
    if $SUDO ethtool -G "$nic" rx 64 tx 64 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}skipped (not supported by driver)${NC}"
    fi

    # 5. Enable NAPI hard-IRQ deferral. After the first hardirq wakes the
    #    NAPI poll, the kernel defers re-arming hardirqs for up to N NAPI
    #    loops, preferring busy-poll to interrupts. With coalescing=0 this
    #    significantly reduces hardirq rate on the isolated core — which is
    #    the opposite of what the original comment in the script claimed.
    echo -n "  NAPI defer    (napi_defer_hard_irqs 50) ... "
    if echo 50 | $SUDO tee "/sys/class/net/$nic/napi_defer_hard_irqs" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}skipped (not supported by kernel)${NC}"
    fi

    echo -e "${GREEN}  NIC tuning applied.${NC}"
}

# Emit a shell snippet that re-applies apply_nic_tuning's settings at boot.
# Used by both networkd-dispatcher scripts and the systemd one-shot.
emit_nic_tuning_snippet() {
    local nic="$1"
    cat <<EOF
ethtool -s $nic speed 100 duplex full autoneg off 2>/dev/null || true
ethtool -C $nic rx-usecs 0 tx-usecs 0 2>/dev/null || true
ethtool -K $nic tso off gso off gro off lro off 2>/dev/null || true
ethtool -G $nic rx 64 tx 64 2>/dev/null || true
echo 50 > /sys/class/net/$nic/napi_defer_hard_irqs 2>/dev/null || true
EOF
}

create_nic_tuning_dispatcher() {
    local nic="${1:-ecat0}"
    local dispatcher_dir="${TUNING_DISPATCHER_DIR:-/etc/networkd-dispatcher/routable.d}"
    local dispatcher_file="${TUNING_DISPATCHER_FILE:-$dispatcher_dir/${nic}-tuning.sh}"

    echo -e "${BLUE}Creating networkd-dispatcher script for persistent NIC tuning...${NC}"

    if [[ ! -d "$dispatcher_dir" ]]; then
        echo -e "${YELLOW}  networkd-dispatcher directory not found ($dispatcher_dir)${NC}"
        echo -e "${YELLOW}  Install with: sudo apt install networkd-dispatcher${NC}"
        echo -e "${YELLOW}  NIC tuning will NOT persist across reboots until this is resolved.${NC}"
        return 1
    fi

    local snippet
    snippet=$(emit_nic_tuning_snippet "$nic")

    $SUDO tee "$dispatcher_file" > /dev/null <<DISPATCHER_EOF
#!/bin/bash
# EtherCAT NIC tuning for low-latency operation
# Auto-generated on $(date)
if [ "\$IFACE" = "$nic" ]; then
$(echo "$snippet" | sed 's/^/    /')
fi
DISPATCHER_EOF

    $SUDO chmod +x "$dispatcher_file"
    echo -e "${GREEN}  Created $dispatcher_file${NC}"
}

remove_nic_tuning_dispatcher() {
    local dispatcher_file="${TUNING_DISPATCHER_FILE:-/etc/networkd-dispatcher/routable.d/ecat0-tuning.sh}"
    if [[ -f "$dispatcher_file" ]]; then
        $SUDO rm -f "$dispatcher_file"
        echo -e "${GREEN}  Removed $dispatcher_file${NC}"
    else
        echo -e "${YELLOW}  No dispatcher script found at $dispatcher_file${NC}"
    fi
}

# ---- RT core selection ----------------------------------------------------
# Sets the global RT_CORE to the user's choice. Returns nonzero on user
# cancel or invalid input.
#
# Changes vs original:
#   - When no isolated cores exist and user picks an unisolated core, require
#     explicit confirmation before proceeding (default no).
#   - Emit a cpuset alternative alongside the isolcpus= hint.
#   - Allow the caller to pre-scope the candidate list via RT_CANDIDATE_CORES
#     so that cpuset callers can offer only cores inside a partition.
select_rt_core() {
    local isolated_range isolated_list num_isolated selected_core=""
    local candidate_range

    # If the caller pre-filtered the candidate list (e.g. a cpuset partition),
    # use that. Otherwise fall back to the kernel's isolated set.
    if [[ -n "${RT_CANDIDATE_CORES:-}" ]]; then
        isolated_range="$RT_CANDIDATE_CORES"
        candidate_range="partition cores"
    else
        isolated_range=$(detect_isolated_cores)
        candidate_range="isolated cores"
    fi

    if [[ -n "$isolated_range" ]]; then
        isolated_list=$(expand_cpu_range "$isolated_range")
        num_isolated=$(echo "$isolated_list" | wc -w | xargs)

        echo ""
        echo -e "${GREEN}Detected $candidate_range: $isolated_range${NC}"
        echo "  Expanded: $isolated_list"
        echo ""

        if [[ "$num_isolated" -eq 1 ]]; then
            selected_core=$(echo "$isolated_list" | xargs)
            echo -e "Only one $candidate_range found."
            read -p "Use core $selected_core for EtherCAT IRQ pinning? [Y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                selected_core=""
            fi
        else
            echo "Multiple $candidate_range available."
            local idx=1 core
            for core in $isolated_list; do
                echo "  [$idx] Core $core"
                ((idx++))
            done
            echo ""
            local selection
            read -p "Select core for EtherCAT IRQ pinning [1-$num_isolated]: " selection
            if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$num_isolated" ]]; then
                selected_core=$(echo "$isolated_list" | awk "{print \$$selection}")
            else
                echo -e "${RED}Invalid selection.${NC}"
                return 1
            fi
        fi
    fi

    # No isolated cores detected, or user declined the isolated option.
    if [[ -z "$selected_core" ]]; then
        local num_cpus c freq selection
        num_cpus=$(get_num_cpus)

        echo ""
        echo -e "${YELLOW}No isolated CPU cores detected (or declined).${NC}"
        echo ""
        echo "Available CPU cores (0-$((num_cpus - 1))):"
        echo ""

        for ((c=0; c<num_cpus; c++)); do
            freq=""
            if [[ -f "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq" ]]; then
                freq=$(cat "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq" 2>/dev/null)
                freq="$((freq / 1000))MHz"
            fi
            echo "  [$((c+1))] Core $c ${freq:+($freq)}"
        done
        echo ""

        read -p "Select core for EtherCAT IRQ pinning [1-$num_cpus]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$num_cpus" ]]; then
            selected_core=$((selection - 1))
        else
            echo -e "${RED}Invalid selection.${NC}"
            return 1
        fi

        echo ""
        echo -e "${YELLOW}WARNING: Core $selected_core is not isolated from the kernel scheduler.${NC}"
        echo "RT performance will be degraded until the core is isolated."
        echo ""
        echo "Options to isolate cores (pick one):"
        echo "  [a] Kernel cmdline (legacy, static):"
        echo "      isolcpus=$selected_core nohz_full=$selected_core rcu_nocbs=$selected_core"
        echo "  [b] cgroup v2 cpuset partition (dynamic):"
        echo "      sudo mkdir /sys/fs/cgroup/rt && \\"
        echo "        echo $selected_core | sudo tee /sys/fs/cgroup/rt/cpuset.cpus && \\"
        echo "        echo isolated | sudo tee /sys/fs/cgroup/rt/cpuset.cpus.partition"
        echo "      (manage_cpusets.sh automates this)"
        echo ""
        read -p "Continue with non-isolated core $selected_core anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}Aborted.${NC}"
            return 1
        fi
    fi

    echo -e "${BLUE}Selected core $selected_core for IRQ pinning.${NC}"
    # RT_CORE is the documented output variable for callers (setup CLI,
    # manage_cpusets.sh ethercat-rt). shellcheck cannot see the cross-file
    # usage so we disable the warning here.
    # shellcheck disable=SC2034
    RT_CORE="$selected_core"
    return 0
}

# ---- Kernel parameter preflight -------------------------------------------
# Accepts both isolcpus= (legacy) and cpuset-partition isolation as evidence
# that a core is isolated. Warns if neither is in effect, or if nohz_full /
# rcu_nocbs are missing (these have no runtime equivalent).
check_kernel_params() {
    local core="$1"

    echo -e "${BLUE}Checking kernel parameters...${NC}"

    local cmdline isolated_sysfs
    cmdline=$(cat /proc/cmdline 2>/dev/null)
    isolated_sysfs=$(detect_isolated_cores)

    local missing=""
    local mechanism=""

    # Isolation: either cmdline isolcpus= or runtime cpuset partition.
    local isolcpus_val
    isolcpus_val=$(parse_isolcpus_cmdline)

    if [[ -n "$isolcpus_val" ]]; then
        mechanism="isolcpus=$isolcpus_val"
        echo -e "${GREEN}  isolation: isolcpus=$isolcpus_val (kernel cmdline)${NC}"
    elif [[ -n "$isolated_sysfs" ]]; then
        mechanism="cpuset partition"
        echo -e "${GREEN}  isolation: cpuset partition active (isolated=$isolated_sysfs)${NC}"
    else
        echo -e "${YELLOW}  isolation: not configured${NC}"
        missing="$missing isolation_mechanism"
    fi

    # Verify the selected core is covered by whichever mechanism is active.
    if [[ -n "$mechanism" && -n "$core" && -n "$isolated_sysfs" ]]; then
        local covered=""
        local c
        for c in $(expand_cpu_range "$isolated_sysfs"); do
            if [[ "$c" == "$core" ]]; then
                covered=yes
                break
            fi
        done
        if [[ -z "$covered" ]]; then
            echo -e "${YELLOW}  WARNING: selected core $core is not in the isolated set${NC}"
        fi
    fi

    local param
    for param in nohz_full rcu_nocbs; do
        if echo "$cmdline" | grep -q "${param}="; then
            echo -e "${GREEN}  ${param}=$(echo "$cmdline" | grep -oE "${param}=[^ ]+" | cut -d= -f2-)${NC}"
        else
            echo -e "${YELLOW}  $param not set (no runtime equivalent — requires reboot to fix)${NC}"
            missing="$missing $param=${core:-<core>}"
        fi
    done

    if echo "$cmdline" | grep -q 'irqaffinity='; then
        echo -e "${GREEN}  irqaffinity=$(parse_irqaffinity_cmdline)${NC}"
    else
        echo -e "${YELLOW}  irqaffinity= not set — default IRQ routing can land on isolated cores${NC}"
        echo -e "${YELLOW}           Recommend adding irqaffinity=$(compute_housekeeping_list) to the cmdline${NC}"
    fi

    if [[ -n "$missing" ]]; then
        echo ""
        echo -e "${YELLOW}Missing kernel parameters:$missing${NC}"
        echo ""
        echo "Add the following to your kernel command line:"
        echo "  ${missing# }"
        echo "  rcu_nocb_poll skew_tick=1 irqaffinity=$(compute_housekeeping_list)"
        echo ""
        echo "Bootloader edit:"
        echo "  - Jetson (extlinux):  /boot/extlinux/extlinux.conf"
        echo "  - GRUB:               /etc/default/grub + 'sudo update-grub'"
        echo "Then reboot."
    fi
}

# ---- Governor lock + workqueue steering -----------------------------------
# Pin the performance governor on every isolated core. DVFS transitions on
# isolated cores are a common source of jitter on Jetson.
lock_isolated_core_governors() {
    local isolated_list c governor_file applied=0 skipped=0
    isolated_list=$(expand_cpu_range "$(detect_isolated_cores)")

    if [[ -z "$isolated_list" ]]; then
        echo -e "${YELLOW}  No isolated cores — skipping governor lock.${NC}"
        return 0
    fi

    echo -e "${BLUE}Locking performance governor on isolated cores...${NC}"
    for c in $isolated_list; do
        governor_file="/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_governor"
        if [[ -w "$governor_file" ]] || $SUDO test -w "$governor_file" 2>/dev/null; then
            if echo performance | $SUDO tee "$governor_file" > /dev/null 2>&1; then
                echo -e "${GREEN}  cpu${c}: governor -> performance${NC}"
                ((applied++))
            else
                ((skipped++))
            fi
        else
            ((skipped++))
        fi
    done

    if [[ "$applied" -eq 0 && "$skipped" -gt 0 ]]; then
        echo -e "${YELLOW}  cpufreq not writable — check jetson_clocks or platform governor.${NC}"
    fi
}

# Restrict unbound kernel workqueues to housekeeping cores so kworker
# threads stop landing on isolated cores.
restrict_workqueue_mask() {
    local mask_file="/sys/devices/virtual/workqueue/cpumask"
    local mask
    mask=$(compute_housekeeping_mask)

    if [[ -z "$mask" || "$mask" == "0" ]]; then
        echo -e "${YELLOW}  No housekeeping cores resolved — skipping workqueue mask.${NC}"
        return 0
    fi

    if [[ ! -e "$mask_file" ]]; then
        echo -e "${YELLOW}  $mask_file not present — kernel does not expose workqueue mask.${NC}"
        return 0
    fi

    echo -e "${BLUE}Restricting unbound workqueues to housekeeping cores (mask 0x$mask)...${NC}"
    if echo "$mask" | $SUDO tee "$mask_file" > /dev/null 2>&1; then
        echo -e "${GREEN}  workqueue.cpumask = 0x$mask${NC}"
    else
        echo -e "${YELLOW}  Write to $mask_file failed (may require kernel arg workqueue.unbound_cpus=)${NC}"
    fi
}
