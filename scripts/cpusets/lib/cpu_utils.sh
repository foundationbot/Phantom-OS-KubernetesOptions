#!/bin/bash
# lib/cpu_utils.sh — CPU list parsing, set ops, and isolation utilities.
#
# Sourceable shell library. No top-level execution beyond the source-guard.
# Shared by setup_ethercat_interface.sh and manage_cpusets.sh.
#
# Every function avoids touching global state (no set -e, no variable leaks
# into caller's namespace beyond its documented outputs on stdout).

[[ -n "${__CPU_UTILS_SH_SOURCED:-}" ]] && return 0
__CPU_UTILS_SH_SOURCED=1

# This library relies on bash scalar-splitting semantics. The production
# consumers (setup_ethercat_interface.sh, manage_cpusets.sh) both run under
# bash. If sourced from a different shell, fail loudly rather than misbehave.
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "cpu_utils.sh requires bash (detected shell: ${0##*/}). Use 'bash' to source." >&2
    return 1 2>/dev/null || exit 1
fi

# Expand a CPU range like "3-5,7" into space-separated cores "3 4 5 7".
# Empty input -> empty output. Returns 1 on malformed input.
expand_cpu_range() {
    local range="$1"
    [[ -z "$range" ]] && return 0

    local result=""
    local part remaining="$range"

    while [[ -n "$remaining" ]]; do
        if [[ "$remaining" == *,* ]]; then
            part="${remaining%%,*}"
            remaining="${remaining#*,}"
        else
            part="$remaining"
            remaining=""
        fi
        part="${part// /}"
        [[ -z "$part" ]] && continue

        if [[ "$part" == *-* ]]; then
            local start=${part%-*}
            local end=${part#*-}
            [[ "$start" =~ ^[0-9]+$ ]] || return 1
            [[ "$end"   =~ ^[0-9]+$ ]] || return 1
            (( start <= end )) || return 1
            local c
            for (( c=start; c<=end; c++ )); do
                result="$result $c"
            done
        else
            [[ "$part" =~ ^[0-9]+$ ]] || return 1
            result="$result $part"
        fi
    done

    echo "$result" | xargs
}

# Compress "10 11 12 13 15" into "10-13,15".
# Deduplicates and sorts; silently drops non-numeric tokens.
compress_cpu_list() {
    local input="$1"
    [[ -z "$input" ]] && return 0

    local sorted
    sorted=$(printf '%s\n' $input | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
    [[ -z "$sorted" ]] && return 0

    local result=""
    local range_start="" range_end="" prev=""
    for c in $sorted; do
        if [[ -z "$range_start" ]]; then
            range_start=$c
            range_end=$c
        elif (( prev + 1 == c )); then
            range_end=$c
        else
            if (( range_start == range_end )); then
                result="$result,$range_start"
            else
                result="$result,$range_start-$range_end"
            fi
            range_start=$c
            range_end=$c
        fi
        prev=$c
    done

    if (( range_start == range_end )); then
        result="$result,$range_start"
    else
        result="$result,$range_start-$range_end"
    fi

    echo "${result#,}"
}

# Union of two CPU ranges (compressed output).
cpu_list_union() {
    local a b
    a=$(expand_cpu_range "$1") || return 1
    b=$(expand_cpu_range "$2") || return 1
    compress_cpu_list "$a $b"
}

# Intersection of two CPU ranges (compressed output; empty if disjoint).
cpu_list_intersect() {
    local a b
    a=$(expand_cpu_range "$1") || return 1
    b=$(expand_cpu_range "$2") || return 1
    local result="" x y
    for x in $a; do
        for y in $b; do
            if [[ "$x" == "$y" ]]; then
                result="$result $x"
                break
            fi
        done
    done
    compress_cpu_list "$result"
}

# Set difference A minus B (compressed output).
cpu_list_diff() {
    local a b
    a=$(expand_cpu_range "$1") || return 1
    b=$(expand_cpu_range "$2") || return 1
    local result="" x y found
    for x in $a; do
        found=0
        for y in $b; do
            if [[ "$x" == "$y" ]]; then
                found=1
                break
            fi
        done
        (( found == 0 )) && result="$result $x"
    done
    compress_cpu_list "$result"
}

# Number of CPUs described by a range.
cpu_list_count() {
    local expanded
    expanded=$(expand_cpu_range "$1") || return 1
    [[ -z "$expanded" ]] && { echo 0; return 0; }
    echo "$expanded" | wc -w | xargs
}

# Check whether CPU list A contains every element of CPU list B.
# Returns 0 if B is a subset of A.
cpu_list_contains() {
    local diff
    diff=$(cpu_list_diff "$2" "$1") || return 2
    [[ -z "$diff" ]]
}

# Total number of logical CPUs the kernel knows about (ignores affinity).
get_num_cpus() {
    nproc --all 2>/dev/null || nproc
}

# Range of CPUs the kernel has present (e.g. "0-13" on Thor).
get_present_cpus() {
    if [[ -r /sys/devices/system/cpu/present ]]; then
        cat /sys/devices/system/cpu/present
    else
        echo "0-$(( $(get_num_cpus) - 1 ))"
    fi
}

# Range of CPUs currently online.
get_online_cpus() {
    if [[ -r /sys/devices/system/cpu/online ]]; then
        cat /sys/devices/system/cpu/online
    else
        echo "0-$(( $(get_num_cpus) - 1 ))"
    fi
}

# True (exit 0) if CPU <N> is online.
cpu_is_online() {
    local cpu="$1" c online
    online=$(expand_cpu_range "$(get_online_cpus)") || return 2
    for c in $online; do
        [[ "$c" == "$cpu" ]] && return 0
    done
    return 1
}

# Detect isolated CPUs. Populated by both isolcpus= and cpuset isolated
# partitions, so this function is mechanism-agnostic.
detect_isolated_cores() {
    local isolated=""
    if [[ -r /sys/devices/system/cpu/isolated ]]; then
        isolated=$(cat /sys/devices/system/cpu/isolated)
    fi
    if [[ -z "$isolated" ]]; then
        isolated=$(parse_isolcpus_cmdline)
    fi
    echo "$isolated"
}

# Extract the raw isolcpus= value from /proc/cmdline, or empty if unset.
# Handles multiple isolcpus= tokens by returning the first one (kernel
# behavior matches — later tokens overwrite but parsing the first is
# sufficient for warning purposes).
parse_isolcpus_cmdline() {
    local cmdline
    [[ -r /proc/cmdline ]] || { echo ""; return 0; }
    cmdline=$(cat /proc/cmdline)
    # Match "isolcpus=<value>" where <value> is anything up to the next
    # whitespace. Newer kernels accept modifiers like "domain,nohz," — we
    # strip them so the returned value is just the CPU list.
    local raw
    raw=$(echo "$cmdline" | grep -oE 'isolcpus=[^ ]+' | head -1 | cut -d= -f2-)
    # isolcpus=nohz,domain,10-13  -> 10-13   (strip leading modifier tokens)
    # isolcpus=10-13              -> 10-13
    if [[ "$raw" == *,* ]]; then
        # If any token is not a cpu-range token, strip leading non-numeric tokens.
        local last_token
        last_token="${raw##*,}"
        if [[ "$last_token" =~ ^[0-9,-]+$ ]]; then
            # Check if the whole thing is already a cpu list.
            if [[ "$raw" =~ ^[0-9,-]+$ ]]; then
                echo "$raw"
            else
                # Mixed — take the trailing cpu-list segment.
                echo "$last_token"
            fi
            return 0
        fi
    fi
    echo "$raw"
}

# Extract the irqaffinity= value from /proc/cmdline, or empty if unset.
parse_irqaffinity_cmdline() {
    [[ -r /proc/cmdline ]] || { echo ""; return 0; }
    grep -oE 'irqaffinity=[^ ]+' /proc/cmdline | head -1 | cut -d= -f2-
}

# Extract the nohz_full= value from /proc/cmdline, or empty if unset.
parse_nohz_full_cmdline() {
    [[ -r /proc/cmdline ]] || { echo ""; return 0; }
    grep -oE 'nohz_full=[^ ]+' /proc/cmdline | head -1 | cut -d= -f2-
}

# Extract the rcu_nocbs= value from /proc/cmdline, or empty if unset.
parse_rcu_nocbs_cmdline() {
    [[ -r /proc/cmdline ]] || { echo ""; return 0; }
    grep -oE 'rcu_nocbs=[^ ]+' /proc/cmdline | head -1 | cut -d= -f2-
}

# Convert a CPU list like "0-9,11" into a lowercase hex bitmask (no 0x prefix).
# Suitable for /proc/irq/*/smp_affinity and /sys/devices/virtual/workqueue/cpumask.
cpu_list_to_hex_mask() {
    local expanded c
    expanded=$(expand_cpu_range "$1") || return 1
    [[ -z "$expanded" ]] && { echo "0"; return 0; }
    local mask=0
    for c in $expanded; do
        mask=$(( mask | (1 << c) ))
    done
    printf "%x" "$mask"
}

# Housekeeping CPUs = present minus (cmdline-isolated ∪ cgroup-partitioned).
#
# Two isolation mechanisms can be in play simultaneously:
#   1. isolcpus= on the kernel cmdline (legacy), reported by
#      /sys/devices/system/cpu/isolated.
#   2. cgroup v2 cpuset partitions managed by manage_cpusets.sh,
#      tracked in /var/lib/manage_cpusets/state.
#
# After 'migrate-cmdline --add-rt-flags' removes isolcpus= from the
# kernel cmdline (the canonical migration), only mechanism (2) remains.
# The lib previously only knew about (1), so compute_housekeeping_list
# silently regressed to "all CPUs" — making the systemd CPUAffinity
# drop-in a no-op and stranding userspace work on the RT cores.
#
# The state file is read directly to keep the lib free of dependencies
# on manage_cpusets.sh's bash functions. Format: 'name|cpus' per line.
compute_housekeeping_list() {
    local present isolated managed combined
    present=$(get_present_cpus)
    isolated=$(detect_isolated_cores)
    managed=$(_read_state_managed_cpus)
    combined=$(cpu_list_union "$isolated" "$managed")
    cpu_list_diff "$present" "$combined"
}

# Read the union of cpus from the manage_cpusets state file, or
# empty when the file is absent / unreadable.
_read_state_managed_cpus() {
    local state_file="${MANAGE_CPUSETS_STATE_FILE:-/var/lib/manage_cpusets/state}"
    local combined="" line cpus
    [[ -r "$state_file" ]] || { echo ""; return 0; }
    while IFS='|' read -r _name cpus; do
        [[ -z "$cpus" ]] && continue
        combined=$(cpu_list_union "$combined" "$cpus")
    done < "$state_file"
    echo "$combined"
}

# Same as above but emitted as a hex bitmask.
compute_housekeeping_mask() {
    cpu_list_to_hex_mask "$(compute_housekeeping_list)"
}
