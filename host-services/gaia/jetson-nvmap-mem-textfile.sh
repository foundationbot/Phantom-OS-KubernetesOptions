#!/usr/bin/env bash
# =============================================================================
# jetson-nvmap-mem-textfile.sh — per-process GPU/iovmm (NVMAP) memory ->
# node-exporter textfile collector.  HOST + ROOT (reads debugfs).
#
# Jetson has no per-process GPU accounting via nvidia-smi / DCGM; the closest
# source is the NVMAP iovmm "clients" table in debugfs, which lists each client
# (process) and its GPU-mapped memory. The format varies by JetPack — this is a
# BEST-EFFORT parse; validate on the device. Override the path with
# NVMAP_CLIENTS if yours differs (e.g. /sys/kernel/debug/nvmap/iovmm/clients).
#
# node-exporter (in the compose) serves whatever .prom files land in TEXTFILE_DIR,
# so this runs alongside jetson-gpu-textfile.sh and needs no compose change.
#
# Usage: sudo TEXTFILE_DIR=/var/lib/gaia/node-textfile ./jetson-nvmap-mem-textfile.sh
# =============================================================================
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/gaia/node-textfile}"
INTERVAL_S="${INTERVAL_S:-5}"
NVMAP="${NVMAP_CLIENTS:-/sys/kernel/debug/nvmap/iovmm/clients}"
OUT="${TEXTFILE_DIR}/jetson_nvmap.prom"
mkdir -p "${TEXTFILE_DIR}"

if [ ! -r "${NVMAP}" ]; then
  echo "cannot read ${NVMAP} (need root + debugfs; path varies by JetPack — set NVMAP_CLIENTS)" >&2
  exit 1
fi

while true; do
  tmp="$(mktemp "${OUT}.XXXXXX")"
  {
    echo "# HELP jetson_gpu_process_memory_bytes Per-process GPU/iovmm (NVMAP) memory on Jetson unified memory."
    echo "# TYPE jetson_gpu_process_memory_bytes gauge"
    # Columns are commonly: CLIENT PROCESS PID SIZE. Skip the header and the
    # trailing 'total' line; emit rows whose 3rd field is a numeric PID.
    tail -n +2 "${NVMAP}" | while read -r c1 c2 c3 c4 _rest; do
      if [ "${c1}" = "total" ]; then continue; fi
      case "${c3}" in ''|*[!0-9]*) continue;; esac
      size="${c4}"
      num="${size%[KkMmGg]}"
      case "${num}" in ''|*[!0-9]*) continue;; esac
      unit=1
      case "${size}" in
        *[Kk]) unit=1024;;
        *[Mm]) unit=1048576;;
        *[Gg]) unit=1073741824;;
      esac
      comm="$(printf '%s' "${c2}" | tr -d '"')"
      printf 'jetson_gpu_process_memory_bytes{pid="%s",comm="%s"} %s\n' "${c3}" "${comm}" "$(( num * unit ))"
    done
  } > "${tmp}"
  chmod 644 "${tmp}"        # mktemp makes 0600; node-exporter runs as nobody
  mv -f "${tmp}" "${OUT}"
  sleep "${INTERVAL_S}"
done
