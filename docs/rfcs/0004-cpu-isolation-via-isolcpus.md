# RFC 0004 — CPU isolation via kernel cmdline + systemd CPUAffinity

**Status:** Implementing
**JIRA:** FIR-269 (supersedes FIR-282 implementation attempts)
**Author:** TBD
**Created:** 2026-05-05
**Supersedes:** the cgroup-v2 cpuset partition approach in
[RFC 0003](./0003-kubelet-cpu-reservation.md). RFC 0003 stays as the
historical record of why the cgroup-partition path was abandoned.

## Problem (one sentence)

Carve a Jetson Thor (or x86 robot) into three CPU groups —
kernel-housekeeping, k8s, host-RT — with reboot-grade enforcement,
without paying the operational cost of cgroup-v2 cpuset partitions
+ kubelet integration.

## Constraints (re-stated for the record)

1. **Single-node deployment.** Each robot runs k0s as
   `controller --enable-worker --single`. No multi-node scheduling.
2. **Fixed CPU layout per robot model.** Jetson Thor = 14 logical cpus;
   the partition (host-RT cpus) is determined by the dma-ethercat
   workload and doesn't vary post-deploy.
3. **Reboots are acceptable.** Operators run `--reset` and reboot
   between bootstrap re-runs anyway. There's no requirement to
   reconfigure cpu isolation at runtime.
4. **Hardware quirks.** Jetson Thor's kernel reports
   `NumCores=1, CoreID=0` for all 14 cpus. Anything depending on
   topology metadata (kubelet `cpuManagerPolicy=static`) breaks.
5. **Operator UX simplicity.** Operators describe "what cpus do
   what" in `host-config.yaml`; bootstrap translates.

Constraint (3) is the lever. The RFC 0003 attempt assumed runtime
cgroup reconfiguration was required and paid a high complexity tax for
it. RFC 0004 trades that for a reboot, gaining simplicity.

## Architecture

```
cpu  0:    kernel housekeeping
            - host kernel scheduler default placement
            - all default IRQs (irqaffinity=0)
            - per-cpu kworkers/0, ksoftirqd/0, RCU callback workers
            - excluded from systemd CPUAffinity → no userspace services here

cpu 1-10:  k0s pool
            - systemd CPUAffinity=1-10 (PID 1 + everything inheriting)
            - k0scontroller, kubelet, containerd, kubepods, all pods
            - robot services run as pods, land here naturally

cpu 11:    SOEM cyclic RT thread
            - isolcpus=11-13 (kernel scheduler skips it)
            - nohz_full=11 (no periodic tick — only this cpu)
            - rcu_nocbs=11-13 (RCU callbacks offloaded)
            - performance governor locked
            - dma_main pins its RT loop here (DMA_RT_CPU=11)

cpu 12:    dma-ethercat helper threads
            - isolcpus=11-13 (no scheduler default placement)
            - DMA_CPU_AFFINITY=11-13 lets dma_main use this for non-RT threads

cpu 13:    EtherCAT NIC IRQs + softirqs + dma-ethercat helper threads
            - isolcpus=11-13
            - smp_affinity for ecat IRQs pinned here
            - shared with other dma-ethercat helper threads (acceptable —
              IRQ handler and helpers belong to the same logical workload)
```

## Mechanism (no kubelet involvement, no cgroup partitions)

### Kernel cmdline tokens

Three tokens for isolation, three for jitter reduction:

```
isolcpus=11-13         # cpus 11-13 excluded from default scheduler
nohz_full=11           # cpu 11 runs without periodic timer tick
rcu_nocbs=11-13        # RCU callbacks offloaded off these cpus
rcu_nocb_poll          # nocb threads use polling (no IPIs)
skew_tick=1            # desync per-cpu timer ticks
irqaffinity=0          # boot-time IRQ default → cpu 0
```

`isolcpus` keeps tasks off 11-13 unless explicitly affined. `nohz_full`
removes the timer interrupt jitter source from the RT loop core
(narrowed to cpu 11 because only the cyclic loop benefits — cpus 12-13
run helper threads and IRQ handlers that need ticks for softirq
processing). `irqaffinity=0` corrals all default IRQs onto cpu 0,
keeping the k8s pool (1-10) quiet.

#### Kernel-config caveat (Jetson Thor / stock L4T)

L4T 36.x ships the Thor kernel with `CONFIG_NO_HZ_FULL` and
`CONFIG_RCU_NOCB_CPU` **not set** (HZ=250, NO_HZ_IDLE only). On this
kernel:

| Token | Effective on stock L4T? |
|---|---|
| `isolcpus=11-13` | ✅ yes (`CONFIG_CPU_ISOLATION=y`) |
| `irqaffinity=0` | ✅ yes (always supported) |
| `skew_tick=1` | ✅ yes |
| `nohz_full=11` | ❌ **silently ignored** — no warning, parser not compiled in |
| `rcu_nocbs=11-13` | ❌ silently ignored |
| `rcu_nocb_poll` | ❌ silently ignored |

The cyclic loop core (cpu 11) will still receive the 250 Hz scheduler
tick and RCU callbacks. Bootstrap writes all six tokens anyway: the
ignored ones are harmless dead text today and become live the moment
someone rebuilds L4T with the matching configs. Documenting them on
the cmdline keeps the operator-visible config consistent with the
intent.

Acontis published EtherCAT-on-Jetson-Thor measurements
([Thor meets EtherCAT](https://www.acontis.com/en/thor-meets-ethercat-acontis-ec-master-on-nvidia-jetson-agx-thor.html)):
stock L4T + no tuning ≈ ±330 µs jitter at 1 ms cycle; **RT kernel +
`isolcpus` alone (no `nohz_full`)** ≈ ±125 µs. Sub-10 µs requires
kernel-bypass NIC drivers, not finer cmdline tuning. So `isolcpus`
provides the bulk of the win on this kernel; `nohz_full`/`rcu_nocbs`
are diminishing returns gated on a kernel rebuild.

These knobs are **kernel-cmdline only** — there is no sysfs/sysctl
runtime equivalent for `nohz_full`, `rcu_nocbs`, `rcu_nocb_poll`,
`skew_tick`, or `isolcpus`. Setting them in systemd unit files would
have no effect; the cmdline (extlinux.conf / GRUB) is the only
configuration surface.

### systemd CPUAffinity drop-in

```ini
# /etc/systemd/system.conf.d/cpuaffinity.conf
[Manager]
CPUAffinity=1-10
```

PID 1 (systemd) sets its own `cpus_allowed=1-10`. Every service
systemd spawns inherits via `sched_setaffinity`. Inheritance is
transitive: `systemd → k0scontroller → kubelet → containerd-shim →
pause container → app container`. They all see `cpus_allowed=1-10`.

Cpu 0 is **excluded from the k8s pool** (not in CPUAffinity) but
**included in the kernel scheduler's default placement domain**
(not in isolcpus). Net effect: kernel-spawned threads (per-cpu
kworkers, ksoftirqd) land on cpu 0; userspace services don't.

### IRQ pinning at runtime (already vendored)

`manage_cpusets ethercat-rt` (vendored from DMA.ethercat) writes
`smp_affinity_list = <irqCore>` for every IRQ owned by the ecat NIC.
The boot-time `irqaffinity=0` is the default; this is the
ecat-specific override. Persisted via the
`ethercat-irq-affinity.service` unit that's installed by the same
subcommand.

### Performance governor lock + workqueue mask (already vendored)

- `lock_isolated_core_governors` writes `performance` to
  `cpu{11,12,13}/cpufreq/scaling_governor`.
- `restrict_workqueue_mask` writes `0-10` to
  `/sys/devices/virtual/workqueue/cpumask` so unbound kworkers stay
  off the isolated cores. (Cpu 0 IS allowed in the workqueue mask —
  cpu 0 jitter doesn't affect the k8s pool.)

## Schema

```yaml
cpuIsolation:
  enabled: true                  # opt-in (defaults: false)
  partitions:                    # cpus to isolate via kernel cmdline
    - {name: ecat, cpus: "11-13"}
  dmaRtCpu: 11                   # SOEM cyclic loop core
                                 #   → DMA_RT_CPU env in dma-ethercat.env
                                 #   → nohz_full=<this> on the kernel cmdline
  nic:
    iface: ecat0
    irqCore: 13                  # NIC IRQs / NAPI / softirqs
    selector:                    # for udev rule (existing)
      mac: aa:bb:cc:dd:ee:ff     # OR pci, OR driver+index
  installAffinityDefaults: true  # default true; the systemd CPUAffinity drop-in
```

**Removed from prior RFC 0003 schema:**
- `cpuIsolation.k8sCpus` — implicit (`online − partitions`); no need
  to override.
- `cpuIsolation.migrateCmdline` (the bool) — kernel cmdline edits are
  always on when `enabled: true`. No more opt-in / opt-out for this
  knob; it's the primary mechanism, not a fallback.

**Kept and reused:**
- `partitions[]`, `dmaRtCpu`, `nic.{iface, irqCore, selector}`,
  `installAffinityDefaults` — same semantics, same operator UX.

## What `manage_cpusets.sh` we keep vs. drop

The vendored `scripts/cpusets/manage_cpusets.sh` (RFC 0003-era) had
two roles: cgroup partition management AND adjacent RT tuning. We
keep the tuning, drop the partitions.

| Subcommand | Status |
|---|---|
| `apply <conf>` | DROP — cgroup partitions no longer needed |
| `install-service` | DROP — `cpusets.service` no longer needed |
| `uninstall-service` | DROP — paired with above |
| `create`, `remove`, `list`, `run` | DROP — partition lifecycle, unused |
| `verify` | KEEP — useful for diagnostics, ignores partition state when none exists |
| `migrate-cmdline` | KEEP — extended to ensure isolcpus/nohz_full/rcu_nocbs are set, not just remove them |
| `install-affinity-defaults` | KEEP — writes the systemd CPUAffinity drop-in |
| `uninstall-affinity-defaults` | KEEP — paired with above |
| `ethercat-rt` | KEEP — IRQ pin + governor lock + workqueue mask + ethercat-irq-affinity.service |

The vendored libraries `lib/cpu_utils.sh` and `lib/nic_rt.sh` stay
relevant. `lib/systemd_units.sh` keeps the affinity-drop-in writer;
the `cpusets.service` writer becomes dead code (left in place; can be
purged later).

## Bootstrap phase 8 (cpu-isolation) — new flow

Replace `manage_cpusets apply` with cmdline+affinity rendering. New
order of operations within phase 8:

1. **Skip-fast** if `cpuIsolation.enabled != true` or block absent.
2. **Compute desired tokens** from host-config:
   - `isolcpus = ∪ cpuIsolation.partitions[].cpus`
   - `nohz_full = cpuIsolation.dmaRtCpu`
   - `rcu_nocbs = ∪ cpuIsolation.partitions[].cpus`
   - `irqaffinity = 0` (constant)
   - `+rcu_nocb_poll +skew_tick=1` (constants)
3. **Render kernel cmdline** via the existing `migrate-cmdline` editor
   (extended to ENSURE tokens, not just strip). Writes
   `/boot/extlinux/extlinux.conf` (Jetson) or `/etc/default/grub`.
   Idempotent: only changes the file if tokens differ.
4. **Render systemd CPUAffinity drop-in.** Compute housekeeping =
   (online cpus) − (partition cpus) − {0}. Write
   `/etc/systemd/system.conf.d/cpuaffinity.conf` with `[Manager]
   CPUAffinity=<housekeeping>`. `daemon-reexec` to apply.
5. **Pin NIC IRQs** via `ethercat-rt --nic <iface> --rt-core
   <irqCore>` — installs `ethercat-irq-affinity.service` for boot
   persistence, locks governors, restricts workqueue mask.
6. **Reboot warning.** If kernel cmdline changed in step 3, write
   `/etc/phantomos/cpu-isolation.reboot-pending` and surface a
   prominent banner: "REBOOT REQUIRED for kernel cmdline changes to
   take effect." On the next boot, the marker is auto-cleared if
   `/proc/cmdline` reflects the desired tokens.

What we DON'T do anymore:
- `manage_cpusets apply` (no cgroup partitions to create)
- `manage_cpusets install-service` (no cpusets.service to enable)
- Kubelet config rendering, node labeling, k8s.slice
- `--cgroup-root`, `cpuManagerPolicy`, `reservedSystemCPUs`,
  `kubeReservedCgroup`
- `cpu_manager_state` migration (no static policy → no checkpoint)

## Bootstrap phase 9 (install-dma-ethercat)

Unchanged from FIR-269. Env-write still produces:

```
DMA_CONFIG=<resolved>
INTERFACE=<nic.iface>
DMA_CPU_AFFINITY=<partition cpus, e.g. 11-13>
DMA_RT_CPU=<dmaRtCpu, e.g. 11>
```

dma-ethercat.service uses `taskset -c $DMA_CPU_AFFINITY` so its
helper threads can use cpus 11-13. Kernel cmdline `isolcpus=11-13`
keeps these cpus off the default scheduler; the explicit affinity
in dma-ethercat.service overrides isolation for this specific
process. RT thread inside the process pins to `DMA_RT_CPU=11`.

## Reboot lifecycle

| State | Bootstrap action |
|---|---|
| First bringup, no cmdline tokens set | Render cmdline + affinity drop-in. Warn REBOOT REQUIRED. |
| Re-run, cmdline already correct | Skip cmdline render. Idempotent re-apply of affinity drop-in (cmp + skip if equal). No reboot. |
| Re-run, partitions changed in host-config | Render new cmdline. Warn REBOOT REQUIRED. |
| After reboot, marker file exists | Auto-clear marker if `/proc/cmdline` matches. |

## Migration from existing FIR-269 deployments

Robots currently running `feat/cpu-isolation-bootstrap` with the cgroup
partition approach:

1. Update host-config.yaml — same schema fields work; just remove
   `migrateCmdline: false` if present (it's now ignored).
2. Re-run bootstrap. New phase 8 renders cmdline + affinity drop-in,
   then warns REBOOT REQUIRED.
3. **Before reboot:** the existing cgroup partition `ecat1` is still
   active (no harm; will simply not be re-created on next boot).
   The old `cpusets.service` will still try to apply on next boot —
   it should be uninstalled. Bootstrap calls
   `manage_cpusets uninstall-service` if a previous-run
   `cpusets.service` is present.
4. Reboot. Kernel comes up with isolcpus, cgroup partition not
   recreated, ecat1 cgroup directory orphan. Cleanup is a no-op
   (empty cgroup, kernel reaps).

## Trade-offs and what we accept

- **Reboot to reconfigure.** If the operator changes `partitions[]`
  or `dmaRtCpu`, a reboot is needed to apply the new kernel cmdline.
  For a single-node test fleet this is fine; for production, plan a
  drain window. Kubelet does not need to be told about isolation —
  changes to non-cmdline pieces (IRQ pin, affinity drop-in) take
  effect with `daemon-reexec` and runtime IRQ rewrite, no reboot.
- **Allocatable.cpu over-reports.** Kubelet still sees 14 cpus as
  Allocatable. A pod requesting 12 CPUs will be admitted by the
  scheduler, and physically run on the 10 cpus available (CFS
  throttles). For our fleet workloads this is acceptable; we can
  add `--system-reserved=cpu=4` later if real over-subscription
  becomes a problem.
- **`isolcpus` is "deprecated upstream."** Has been for ~5 years;
  no concrete sunset. Practical horizon is 5-10 more years before
  it's actually removed. When that happens, we revisit RFC 0003 with
  a more mature kubelet/k0s integration story.
- **No per-pod CPU pinning.** Kubelet's `cpuManagerPolicy=static` is
  off. Guaranteed-QoS pods with integer CPU requests don't get
  exclusive cpus. For our workloads (Burstable QoS, no µs-latency
  pods) this is fine. The dma-ethercat process — the only true
  hard-RT workload — runs OUTSIDE k8s, pinned by systemd.

## Open work (after this RFC lands)

- Verify on `mk11000011` (Jetson) and `ak-007` (x86) that the cmdline
  edit works on both extlinux and GRUB.
- Decide whether to extend `migrate-cmdline` or write a new
  `ensure-cmdline-tokens` subcommand. Likely just extend the
  existing function with an `ensure` mode.
- Write a small post-reboot verification script (`positronic.sh
  cpu-isolation status` or similar) that checks `/proc/cmdline`,
  `/sys/devices/system/cpu/{isolated,nohz_full}`, `CPUAffinity`,
  IRQ pins, governor, and the LOC line in `/proc/interrupts` (250 Hz
  ticks should *not* appear on `dmaRtCpu` once NO_HZ_FULL is live).
  On stock L4T, expect `isolated` to match partitions but `nohz_full`
  to be empty — log as info, not error.
- Evaluate rebuilding L4T with `CONFIG_NO_HZ_FULL=y` +
  `CONFIG_RCU_NOCB_CPU=y` if measured jitter on the SOEM cyclic loop
  exceeds the budget once `isolcpus`-only is in place. Acontis's
  ±125 µs at 1 ms cycle is a useful reference baseline.
