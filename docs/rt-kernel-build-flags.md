# Custom RT kernel build flags — Jetson AGX Thor (T5000)

Build requirements for a partner compiling the kernel for our real-time EtherCAT control workload.

**Target:** L4T r38.4, kernel 6.8.12, custom build with `PREEMPT_RT`.

**Why a custom build:** The stock `*-tegra` kernel ships `PREEMPT` (not `PREEMPT_RT`), and NVIDIA's *prebuilt* RT kernel is built **without** `CONFIG_NO_HZ_FULL` or `CONFIG_RCU_NOCB_CPU`. On that prebuilt kernel `nohz_full=` / `rcu_nocbs=` on the boot cmdline are silently ignored — there is no `/sys/devices/system/cpu/nohz_full` and no `rcuo*` kthreads. The only way to get true full-tickless on the isolated control cores is to compile the flags below in.

---

## Required `CONFIG_*` settings

### Preemption (RT core)
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_EXPERT` | `y` | Exposes the expert menu; gates visibility of `PREEMPT_RT` and the RCU tuning options below. |
| `CONFIG_PREEMPT_RT` | `y` | The fully-preemptible real-time model. Converts most kernel locks to sleeping/priority-inheriting mutexes and threads nearly all interrupt handling, so a high-priority task can preempt almost any kernel section. This is the core requirement — `PREEMPT=y` alone is not enough. |
| `CONFIG_PREEMPT_DYNAMIC` | **not set** | Prevents the preemption model from being selected/downgraded at boot. Keeps the RT model static and guaranteed. |

### Full dynticks + RCU offload
*(So isolated cores run tickless and shed RCU work — the flags the prebuilt kernel omits.)*
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_NO_HZ_FULL` | `y` | Full dynticks. Stops the periodic scheduler tick on a CPU running a single runnable task, so the isolated control cores are not interrupted ~1000×/s. Eliminates the dominant source of cyclic jitter on the RT cores. Requires the `nohz_full=` cmdline arg to name the cores. |
| `CONFIG_RCU_EXPERT` | `y` | Exposes the RCU offload options (incl. `RCU_NOCB_CPU`) in the config. |
| `CONFIG_RCU_NOCB_CPU` | `y` | Allows RCU grace-period callback processing to be offloaded off named CPUs to `rcuo*` kthreads. Without this, `rcu_nocbs=` does nothing and RCU softirq work still lands on the control cores. |
| `CONFIG_CONTEXT_TRACKING` | `y` | Tracks kernel/user transitions so the kernel knows when a full-dynticks CPU is in userspace and the tick can safely be stopped. Auto-selected by `NO_HZ_FULL`; listed for clarity. |
| `CONFIG_CPU_ISOLATION` | `y` | Enables `isolcpus=` / `nohz_full=` / housekeeping infrastructure that keeps general kernel work off the isolated cores. Auto-selected by `NO_HZ_FULL`; listed for clarity. |

### Timers
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_HIGH_RES_TIMERS` | `y` | High-resolution timers backed by the hardware timer, giving sub-microsecond timer granularity instead of one-jiffy resolution. Required for tight cyclic control loops. |
| `CONFIG_HZ_1000` / `CONFIG_HZ` | `y` / `1000` | 1 ms scheduler tick on the housekeeping cores. The isolated cores go tickless regardless (see `NO_HZ_FULL`), so this governs housekeeping-core granularity only. |

### CPU frequency / scaling
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE` | `y` | Default governor pins CPUs at max frequency rather than scaling on demand, removing DVFS ramp-up latency. (We additionally lock clocks at runtime via MAXN + `jetson_clocks`.) |

### IRQ threading
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_IRQ_FORCED_THREADING` | `y` | Allows hard IRQ handlers to run in schedulable kthreads so they can be prioritized below the control task. `PREEMPT_RT` forces this on; set explicitly for clarity. |

### Validation tracers
*(Compiled in, off by default — used to qualify the delivered build.)*
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_HWLAT_TRACER` | `y` | Detects hardware/firmware-induced latency (e.g. SMIs) invisible to the scheduler. |
| `CONFIG_OSNOISE_TRACER` | `y` | Measures OS-induced noise (IRQs, NMIs, softirqs) stealing time from a running task. |
| `CONFIG_PREEMPTIRQ_DELAY_TEST` | `m` | Test module to inject preempt/IRQ-disable delays for validating the latency tooling. |

### Disable for production (jitter / latency sources)
| Flag | Setting | Meaning / effect |
|---|---|---|
| `CONFIG_DEBUG_PREEMPT` | **not set** | Removes preempt-count debug accounting from the hot path. |
| `CONFIG_PROVE_LOCKING` | **not set** | Disables lockdep — heavy per-lock validation overhead unacceptable in production RT. |
| `CONFIG_DEBUG_ATOMIC_SLEEP` | **not set** | Removes atomic-context sleep checks from the hot path. |
| `CONFIG_LATENCYTOP` | **not set** | Removes per-task latency accounting overhead. |

---

## Boot cmdline we will apply (informational — not a build setting)

On a 14-core T5000 we isolate cores 11–13 for the control loop:

```
nohz_full=11 rcu_nocbs=11-13 rcu_nocb_poll skew_tick=1 irqaffinity=0-10 isolcpus=managed_irq,11-13
```

These only take effect if `NO_HZ_FULL` and `RCU_NOCB_CPU` are compiled in — hence the requirements above.

---

## Acceptance checks (run on the delivered kernel)

```bash
zcat /proc/config.gz | grep -E 'PREEMPT_RT|NO_HZ_FULL|RCU_NOCB|RCU_EXPERT|^CONFIG_HZ='
uname -v                                  # must contain: SMP PREEMPT_RT
cat /sys/devices/system/cpu/nohz_full     # must list 11-13 (not absent/empty)
ps -e | grep rcuo                         # rcuo* offload kthreads must exist

# Latency target on isolated core under load:
taskset -c 0-10 stress-ng --cpu 11 --timeout 30s &
cyclictest -p99 -a11 -t1 -m -D20 -q       # expect max < ~10 µs
```

---

*Related: [`preempt_rt_update.md`](preempt_rt_update.md) — fleet rollout runbook for the prebuilt RT kernel (documents the `NO_HZ_FULL`/`RCU_NOCB` gap that motivates this custom build).*
