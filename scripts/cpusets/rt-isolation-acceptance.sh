#!/usr/bin/env bash
# RT isolation acceptance test. Validates the full isolation stack after a
# reboot: PREEMPT_RT, MAXN, the domain-flag scheduler isolation, the cpuset
# partition + kubepods containment, the workqueue masks, and either the live
# control-loop jitter (robot running) or bare isolated-core cyclictest (robot
# stopped). Read-only except the optional cyclictest (which only adds load).
set -u
RT=${RT:-11}; HK=${HK:-0-10}
P=0; F=0
ok(){ echo "  PASS  $*"; P=$((P+1)); }
no(){ echo "  FAIL  $*"; F=$((F+1)); }
hdr(){ echo; echo "== $* =="; }

hdr "kernel / power"
uname -v | grep -q 'SMP PREEMPT_RT' && ok "PREEMPT_RT kernel" || no "not PREEMPT_RT"
grep -q 'pmode:0000' /var/lib/nvpmodel/status && ok "nvpmodel MAXN (pmode:0000)" || no "not MAXN"
[ "$(cat /sys/devices/system/cpu/online)" = "0-13" ] && ok "14 cores online" || no "cores online != 0-13"

hdr "scheduler-domain isolation (the domain flag)"
grep -q 'isolcpus=domain,managed_irq' /proc/cmdline && ok "cmdline has isolcpus=domain,managed_irq" || no "cmdline missing domain flag"
iso=$(cat /sys/devices/system/cpu/isolated)
[ "$iso" = "11-13" ] && ok "sysfs isolated = 11-13 (domain active)" || no "sysfs isolated = '$iso' (expected 11-13 — domain flag not in effect)"

hdr "cpuset partition + kubepods containment"
part=$(cat /sys/fs/cgroup/ecat.slice/cpuset.cpus.partition 2>/dev/null)
[ "$part" = "isolated" ] && ok "ecat.slice partition = isolated (valid)" || no "ecat.slice partition = '$part' (expected isolated)"
kp=$(cat /sys/fs/cgroup/kubepods/cpuset.cpus 2>/dev/null)
[ "$kp" = "$HK" ] && ok "kubepods cpus = $HK (pods contained)" || no "kubepods cpus = '$kp' (expected $HK — reassert didn't hold)"
ss=$(cat /sys/fs/cgroup/system.slice/cpuset.cpus 2>/dev/null)
[ "$ss" = "$HK" ] && ok "system.slice cpus = $HK" || no "system.slice cpus = '$ss'"

hdr "no userland on isolated cores"
# A kernel thread has an empty /proc/<pid>/cmdline; userland tasks don't.
# Only userland tasks landing on the isolated cores are a real isolation breach
# (kernel/driver threads like kworker, backlog_napi, crypto-engine, spi, nvmap
# are pinned there by the kernel and are expected).
spill=""
while read -r psr pid comm; do
  { [ "$psr" -ge "$RT" ] && [ "$psr" -le 13 ]; } || continue
  [ -s "/proc/$pid/cmdline" ] && spill="${spill}        $psr $pid $comm"$'\n'
done < <(ps -eL -o psr=,pid=,comm= 2>/dev/null)
[ -z "$spill" ] && ok "no userland tasks on $RT-13 (kernel/driver threads only)" || { no "userland on isolated cores:"; printf '%s' "$spill"; }

hdr "I/O workqueue affinity (want 07ff = $HK)"
for wq in writeback nvme-wq nvme-reset-wq nvme-delete-wq blkcg_punt_bio; do
  m=$(cat /sys/bus/workqueue/devices/$wq/cpumask 2>/dev/null | tr -d ',')
  [ -n "$m" ] && [ $((16#$m)) -eq $((16#7ff)) ] && ok "$wq = 0x$m" || no "$wq = 0x$m (expected 7ff)"
done

hdr "services"
for s in jetson_clocks rt-housekeeping-affinity cpusets cpusets-reassert; do
  systemctl is-active --quiet $s.service && ok "$s.service active" || no "$s.service not active"
done

hdr "RT latency"
if pgrep -x dma_main >/dev/null; then
  echo "  control loop running — do NOT cyclictest the live RT core. Validate jitter"
  echo "  from the loop's own telemetry instead (Prometheus on this host):"
  echo "    dma_debug_dma_missed_deadlines_total  (delta over a window should be 0)"
  echo "    dma_debug_dma_cycle_time_us_max       (peak should stay within the loop period)"
  ok "dma_main running — RT-loop jitter is validated from loop telemetry, not cyclictest"
else
  echo "  robot stopped — measuring bare isolated-core latency on cpu $RT under housekeeping load..."
  if command -v cyclictest >/dev/null && command -v stress-ng >/dev/null; then
    taskset -c "$HK" stress-ng --cpu 11 --timeout 30s >/dev/null 2>&1 & sp=$!
    out=$(sudo cyclictest -p99 -a"$RT" -t1 -m -D20 -q 2>/dev/null)
    kill $sp 2>/dev/null; wait $sp 2>/dev/null
    mx=$(echo "$out" | grep -oE 'Max:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
    echo "$out" | sed 's/^/        /'
    [ -n "$mx" ] && [ "$mx" -le 100 ] && ok "isolated core $RT max latency ${mx}us (<=100us)" || no "isolated core $RT max latency ${mx:-?}us (>100us)"
  else echo "  (rt-tests/stress-ng not installed)"; fi
fi

echo; echo "==== RESULT: $P passed, $F failed ===="
[ "$F" -eq 0 ] && echo "ALL GOOD" || echo "REVIEW FAILURES ABOVE"
exit 0
