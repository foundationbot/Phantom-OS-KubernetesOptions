# RFC-0009: RT isolation layered stack

**Status:** Implemented (FIR-316, PR #38)
**Supersedes:** Aspects of [0004-cpu-isolation-via-isolcpus.md](./0004-cpu-isolation-via-isolcpus.md) — the legacy plain `isolcpus=` form is no longer used for scheduler isolation.
**Related:** [`docs/internal/cpu-isolation.md`](../cpu-isolation.md) — operator procedure for setup.

## Problem

EtherCAT and other RT control loops run on dedicated cores. Default Linux scheduling, IRQ routing, watchdog kthreads, and per-CPU housekeeping work add tail-latency jitter that violates the control-loop deadline budget. We need a layered isolation stack that pushes worst-case wake-up latency on isolated cores into the low-µs range under load.

Measured baseline on Thor (`ch4`, kernel 6.8.12-tegra) with no isolation: cyclictest max latency **521 µs**. Target: < 30 µs sustained.

## Why isolation is layered

There is no single Linux knob that produces "RT-isolated CPU." The jitter sources are distinct and each requires its own mechanism. Picking only one or two mechanisms leaves the others uncontrolled. The stack below addresses each known jitter source explicitly.

| Layer | Mechanism | What it isolates | Cannot be replaced by |
|---|---|---|---|
| 1. Scheduler | cgroup-v2 cpuset partition (`cpuset.cpus.partition=isolated`) | Userspace processes, kubelet pods, container workloads | `isolcpus=` (deprecated for scheduler isolation; can't be re-partitioned at runtime) |
| 2. Driver-managed IRQs | `isolcpus=managed_irq,<cpus>` on kernel cmdline | PCIe/MSI-X vectors allocated by drivers with `IRQF_MANAGED` (NVMe, modern NICs) | Runtime `smp_affinity` writes (silently ignored for managed vectors); cpuset partitions (no influence over IRQ vector placement) |
| 3. Driver IRQs (manageable) | `/proc/irq/N/smp_affinity` writes pinning each IRQ to housekeeping | Non-managed IRQs (most legacy / discrete-interrupt drivers, including the EtherCAT NIC's IRQ ring) | Nothing — this is the runtime knob |
| 4. Unbound workqueues | `/sys/devices/virtual/workqueue/cpumask` | Kernel `kworker/u*` threads that aren't pinned to a specific CPU | Per-workqueue `cpumask` files (needed only for chatty drivers with their own bound workqueues — beyond scope here) |
| 5. CPU governor | Per-CPU `cpufreq/scaling_governor = performance` | DVFS-induced frequency transitions on isolated cores (a known jitter source on Jetson) | `cpufreq.default_governor` (system-wide; we want housekeeping cores to retain ondemand for power) |
| 6. Kernel timers | `kernel.timer_migration = 0` | hrtimer migration between CPUs when the originator was idle | `nohz_full=` (kills the periodic tick but not migration) |
| 7. Lockup watchdog | `kernel.watchdog_cpumask = <housekeeping>` | Per-CPU `watchdog/N` kthread wake-ups on isolated cores | `nosoftlockup` / `nowatchdog` (also kills the safety net on housekeeping cores) |
| 8. Tegra-specific kthreads | Runtime `taskset` sweep over `nvgpu_*`, `nvhost-*`, `tegra*`, `nv-*` kthreads | NVIDIA Tegra service kthreads that spawn early with a wide cpu mask | Per-CPU kthreads (`PF_NO_SETAFFINITY`) — these are accepted as residual jitter sources |
| 9. Periodic tick | `nohz_full=<rt-cpus>` (kernel-build-dependent) | Scheduler tick on isolated cores when only one runnable task | n/a when kernel is built without `CONFIG_NO_HZ_FULL` (silently no-ops) |
| 10. RCU callbacks | `rcu_nocbs=<rt-cpus>` + `rcu_nocb_poll` | RCU callback work running on isolated cores | n/a |

## Mechanism choices and rejected alternatives

### Why cgroup-v2 cpuset partitions over `isolcpus=`?

`isolcpus=` is the legacy mechanism. It's static (requires reboot to change), and the kernel docs themselves note it remains for backward compatibility but discourage new use. cpuset partitions:
- Can be created, resized, and destroyed at runtime
- Compose naturally with Kubernetes (kubelet's `kubepods` cgroup can be shrunk to housekeeping CPUs before the RT partition is created)
- Are observable via `/sys/fs/cgroup/cpuset.cpus.isolated`

Migration path: `manage_cpusets.sh migrate-cmdline` strips legacy `isolcpus=<cpus>` from the cmdline. Only the new `managed_irq` modifier survives.

### Why `isolcpus=managed_irq` is still on the cmdline

Driver-managed IRQ vectors (PCIe MSI-X with `IRQF_MANAGED`, used by NVMe and modern NICs with RSS) are allocated at driver probe time based on `cpu_possible_mask` minus the `managed_irq` exclusion list. Runtime writes to `/proc/irq/N/smp_affinity` against managed vectors are silently ignored, and cpuset partitions cannot reach them. The `managed_irq` modifier to `isolcpus=` is the only kernel knob that controls this — it is **not** scheduler isolation, despite the shared `isolcpus=` keyword.

### Why `watchdog_cpumask` over `nosoftlockup`

`nosoftlockup` and `nowatchdog` disable the lockup detector entirely, removing the safety net from housekeeping cores too. `watchdog_cpumask` restricts only which CPUs the watchdog runs on, keeping the detector active where it's useful. Strict superset.

### Why `noirqdebug` was rejected

Disables the kernel's spurious-IRQ detector. Marginal jitter benefit (sub-µs on healthy hardware) and loses a useful diagnostic when a shared IRQ line misbehaves. Not worth the trade.

### Why we accept residual jitter from per-CPU kthreads

`migration/N`, `ksoftirqd/N`, `idle_inject/N`, `cpuhp/N`, and others have `PF_NO_SETAFFINITY` set by the kernel. They cannot be moved, by design — they exist to do per-CPU bookkeeping. `nohz_full` quiets most of them between work units, but not entirely. This is acknowledged as residual jitter; the worst-case impact is bounded and small.

## How the layers compose at boot

```
boot → kernel cmdline takes effect
       (managed_irq exclusion applied at driver probe,
        nohz_full / rcu_nocbs / irqaffinity registered)
   │
   ▼
cpusets.service (oneshot, before docker / kubelet / multi-user.target)
   │  reads /etc/cpusets.conf
   │  creates cgroup-v2 partition with cpuset.cpus.partition=isolated
   │  populates /sys/fs/cgroup/cpuset.cpus.isolated
   ▼
ethercat-irq-affinity.service (oneshot, after network.target)
   │  pins NIC IRQs (smp_affinity writes for non-managed vectors)
   │  ethtool NIC tuning (rx/tx ring, NAPI defer, offloads)
   │  locks performance governor on every isolated cpu
   │  restricts workqueue cpumask to housekeeping
   │  writes /proc/sys/kernel/timer_migration=0
   │  writes /proc/sys/kernel/watchdog_cpumask=<housekeeping>
   │  on Tegra: taskset sweep over nvgpu_* / nvhost-* / tegra* / nv-* kthreads
   ▼
multi-user.target reached, k0s / docker / user sessions start
   (all constrained to housekeeping cores by the partition + systemd
    default CPUAffinity drop-in at /etc/systemd/system.conf.d/cpuaffinity.conf)
```

The ordering guarantee: cpusets.service must finish before ethercat-irq-affinity reads the isolated-cpus state. Currently this works because ethercat-irq-affinity has `After=network.target` (which starts after cpusets.service finishes its `Before=multi-user.target` ordering). For belt-and-suspenders, the boot script also falls back to `/sys/fs/cgroup/cpuset.cpus.isolated` if `/sys/devices/system/cpu/isolated` is empty (the latter only reflects cmdline `isolcpus=`, which we no longer use).

## What is *not* in scope

- **NIC RSS / RX queue distribution** — `ethtool -X` rx-flow-hash configuration to keep RSS queues off isolated cores. Today the EtherCAT NIC is single-queue so this doesn't matter; for future multi-queue NICs in the RT path this would be a follow-up.
- **PCIe ASPM tuning** — `pcie_aspm=off` or per-link power-state control. Not yet measured as a meaningful jitter source on Thor.
- **CPU C-state restriction** — `intel_idle.max_cstate=` / `processor.max_cstate=` to prevent deep idle on isolated cores. Already implied by `cyclictest -m` (which writes 0 to `/dev/cpu_dma_latency`) and the performance-governor lock.
- **THP / KSM disable** — transparent huge page collapse and KSM scanning can introduce jitter via TLB shootdowns. Not currently disabled; impact on the RT path has not been measured.
- **Real-time kernel (`PREEMPT_RT`)** — this stack runs on the stock Tegra kernel. A `PREEMPT_RT` kernel would tighten the tail further but requires a separate kernel build pipeline.

## Operator surface

Two scripts, one service, three sysctl writes, one cmdline migration. From the operator's perspective:

```bash
# One-time per host:
sudo manage_cpusets.sh apply /etc/cpusets.conf
sudo manage_cpusets.sh install-service /etc/cpusets.conf
sudo manage_cpusets.sh install-affinity-defaults
sudo manage_cpusets.sh ethercat-rt <partition-name>
sudo manage_cpusets.sh migrate-cmdline --add-rt-flags
sudo reboot
```

`bootstrap-robot.sh --cpu-isolation` chains these from `host-config.yaml`'s `cpuIsolation:` block on a fresh robot.

### Verification

`manage_cpusets.sh status` surfaces every relevant state in one view: cmdline flags, sysfs-isolated set, cgroup-v2 isolated set, managed_irq presence and partition-state agreement, housekeeping CPUs, partition list, systemd affinity drop-in, cpusets.service state.

`check_kernel_params` (called by `ethercat-rt` setup) warns when any of `nohz_full`, `rcu_nocbs`, `irqaffinity`, or `isolcpus=managed_irq` is missing from the cmdline relative to current partition state, with a remediation command in every warning.

## Validation

cyclictest on ch4 (Thor, kernel 6.8.12-tegra, kernel built without `CONFIG_NO_HZ_FULL` or `CONFIG_SOFTLOCKUP_DETECTOR`):

```
cyclictest -m -p99 -t1 -a 13 -i 200 -l 1000000 -q
```

| State | Min | Avg | Max | Notes |
|---|---|---|---|---|
| Un-isolated (no partition, plain `taskset -c 13`) | 1 µs | 2 µs | **521 µs** | Baseline before any RT setup |
| Fully isolated (FIR-316 stack via `manage_cpusets.sh run`) | 2 µs | 2 µs | **10 µs** | Cpuset partition + cmdline flags + boot script tweaks |

52× reduction in max latency. The delta is the *whole* stack vs nothing; a future test would compare per-layer contribution.

On ch4 the layers that materially contribute are scheduler isolation (cpuset partition), IRQ pinning, `managed_irq`, `timer_migration=0`, governor lock, and the Tegra kthread sweep (moved 10 kthreads). Layers that silently no-op on this specific kernel build: `nohz_full=` (no `CONFIG_NO_HZ_FULL`), `watchdog_cpumask` (no `CONFIG_SOFTLOCKUP_DETECTOR` — file does not exist).

## Open items

- Pure FIR-316 delta measurement (vs a pre-isolated baseline that already has the cpuset partition + legacy cmdline flags) to isolate the new RT tweaks' individual contribution. Tracked as a follow-up; not a merge blocker.
- Repeat the cyclictest pass on an x86 RT robot when one becomes available.
- Stress-test (`stress-ng --cpu N --taskset 0-10`) while cyclictest runs in the partition. Today's measurement was idle-baseline only.
