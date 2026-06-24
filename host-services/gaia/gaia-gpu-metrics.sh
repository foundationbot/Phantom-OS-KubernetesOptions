#!/bin/sh
# =============================================================================
# gaia — GPU metrics via nvidia-smi -> node-exporter textfile (HOST-side)
# =============================================================================
# Jetson Thor ships /usr/sbin/nvidia-smi (older Jetsons don't). It returns GPU
# util%, mem-util%, temp and power in one fast (~40ms) query that does NOT stall
# on a gated GPU — unlike the gpu-thermal sysfs read. nvidia-smi needs host
# nvidia libs, so this runs on the HOST (not the alpine sidecar) and writes into
# the shared textfile dir ($TEXTFILE_DIR) that node-exporter's textfile collector
# serves — same dir the tegra-metrics sidecar and the NVMAP collector write to.
#
# Note: memory.used/total are [N/A] on Thor (unified memory — see node_memory_*).
# Polling nvidia-smi every few seconds lightly touches the GPU; raise INTERVAL
# if you want to disturb GPU power management less.
# =============================================================================
set -u
OUT="${OUT:-${TEXTFILE_DIR:-/var/lib/gaia/node-textfile}/tegra_gpu.prom}"
INTERVAL="${INTERVAL:-5}"
Q="utilization.gpu,utilization.memory,temperature.gpu,power.draw"

while :; do
  [ -d "${OUT%/*}" ] || { sleep "$INTERVAL"; continue; }   # textfile dir not ready
  line="$(timeout 4 nvidia-smi --query-gpu=$Q --format=csv,noheader,nounits 2>/dev/null | head -1)"
  tmp="$OUT.tmp"
  {
    echo "# TYPE tegra_gpu_utilization_ratio gauge"
    echo "# TYPE tegra_gpu_mem_utilization_ratio gauge"
    echo "# TYPE tegra_gpu_temp_celsius gauge"
    echo "# TYPE tegra_gpu_power_watts gauge"
    echo "# TYPE tegra_gpu_query_ok gauge"
    if [ -n "$line" ]; then
      echo "$line" | awk -F', *' '{
        if ($1 ~ /^[0-9.]+$/) printf "tegra_gpu_utilization_ratio %.4f\n", $1/100
        if ($2 ~ /^[0-9.]+$/) printf "tegra_gpu_mem_utilization_ratio %.4f\n", $2/100
        if ($3 ~ /^[0-9.]+$/) printf "tegra_gpu_temp_celsius %s\n", $3
        if ($4 ~ /^[0-9.]+$/) printf "tegra_gpu_power_watts %s\n", $4
      }'
      echo "tegra_gpu_query_ok 1"
    else
      echo "tegra_gpu_query_ok 0"
    fi
    # Per-process GPU memory: which processes hold a CUDA/GPU context, and how
    # much GPU memory each uses. This is how you tell a GPU process from a
    # CPU-only one. Empty when nothing is using the GPU. (On Thor unified memory,
    # this GPU memory is part of system RAM; node_memory_* is the whole pool.)
    echo "# TYPE tegra_gpu_process_memory_bytes gauge"
    timeout 4 nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory \
      --format=csv,noheader,nounits 2>/dev/null | awk -F', *' '{
        if ($1 ~ /^[0-9]+$/) {
          name=$2; gsub(/[\\"]/,"",name); gsub(/.*\//,"",name);
          mem=($3 ~ /^[0-9.]+$/) ? $3*1048576 : 0;
          printf "tegra_gpu_process_memory_bytes{pid=\"%s\",procname=\"%s\"} %d\n", $1, name, mem
        }
      }'
  } > "$tmp" 2>/dev/null
  chmod 644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$OUT" 2>/dev/null
  sleep "$INTERVAL"
done
