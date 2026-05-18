# dma-ethercat .deb changes for Option B (FIR-318 follow-up)

> This document describes the changes required in the **`dma-ethercat`** package repo (the one that builds `dma-ethercat-arm64-V-1-0-X.deb`) to complete the long-term Option B isolation architecture. The complementary bootstrap-side changes are already landed in `Phantom-OS-KubernetesOptions` on commit `e916562` (FIR-318).

**Status:** Pending PR in the `dma-ethercat` repo.
**Validated empirically:** main process affinity narrows to `DMA_RT_CPU` after dma_main startup on mk11000009 (commit `e916562` testing) — `dma_main` already does its own `sched_setaffinity`, so the `taskset` wrapper in the unit's `ExecStart` is redundant.

## Why these changes are needed

`Phantom-OS-KubernetesOptions` now writes two systemd artifacts per host (FIR-318):

1. `/etc/systemd/system/<partition-name>.slice` — a top-level (root-child) slice with `AllowedCPUs=<isolated cpus>`, rendered from `host-config.yaml:cpuIsolation.partitions[]`.
2. `/etc/systemd/system/dma-ethercat.service.d/10-slice.conf` — a drop-in with `Slice=<partition-name>.slice` and `CPUAffinity=` (empty, to clear the manager-wide drop-in).

The drop-in works today *with* the current `.deb` because `taskset -c $DMA_CPU_AFFINITY` is a no-op when `DMA_CPU_AFFINITY` matches the slice's `AllowedCPUs`. But the `taskset` wrapper is now redundant and the unit can be simplified.

## Required changes

### 1. Drop `taskset -c` from `ExecStart`

**Current** (`/usr/lib/systemd/system/dma-ethercat.service`):
```ini
[Service]
ExecStart=/usr/bin/taskset -c ${DMA_CPU_AFFINITY} /usr/bin/dma_main --config ${DMA_CONFIG} --cpu ${DMA_RT_CPU} --interface ${INTERFACE} --enable-motor-enable --enable-emcy-monitor --enable-pdo-diagnostics --enable-slave-recovery
```

**Proposed:**
```ini
[Service]
ExecStart=/usr/bin/dma_main --config ${DMA_CONFIG} --cpu ${DMA_RT_CPU} --interface ${INTERFACE} --enable-motor-enable --enable-emcy-monitor --enable-pdo-diagnostics --enable-slave-recovery
```

Rationale:
- The cpuset partition + slice already constrain the service's cgroup-v2 `cpuset.cpus` ceiling to the isolated cpus. `taskset` to widen back out is rejected by the kernel anyway (`EINVAL`).
- `dma_main` internally narrows its main thread to `--cpu DMA_RT_CPU` via `sched_setaffinity` (validated: main PID affinity mask on mk11000009 is `0x800` = cpu 11 after startup, i.e. `DMA_RT_CPU`).
- Removing the `taskset` wrapper eliminates one process and one EnvironmentFile dependency on `DMA_CPU_AFFINITY`.

### 2. Remove `DMA_CPU_AFFINITY` from the package-managed `dma-ethercat.env`

Currently `/etc/dma/dma-ethercat.env` is a dpkg conffile that bootstrap edits to set:
```
INTERFACE=ecat1
DMA_CPU_AFFINITY=11-13
DMA_RT_CPU=11
```

`DMA_CPU_AFFINITY` becomes unused once `taskset` is dropped from ExecStart. Two options:

**Option 2a (recommended):** remove `DMA_CPU_AFFINITY` from the `.deb`'s default env file and from any postinst logic. Bootstrap drops its env-write of this key too.

**Option 2b:** leave `DMA_CPU_AFFINITY` in the env file as an informational comment for operators who want to manually pin via `taskset -p $(pidof dma_main)`. Costs nothing and keeps the value visible.

### 3. Ensure `dma_main` always pins the RT thread to `DMA_RT_CPU`

If not already done, add explicit `pthread_setaffinity_np(rt_thread, ...)` for the SOEM RT loop to `--cpu` value. The main thread's affinity is set via the kernel's cgroup-v2 ceiling (= 11-13 from the slice). The RT thread needs to be pinned to a single cpu (11) for deterministic latency.

A spot check from the mk11000009 test:
- Main PID affinity = `0x800` = cpu 11 — looks like dma_main already does this for the main thread.
- Cycle latency `total=807us` against `budget=2000us`, `missed=0` — RT thread is being pinned correctly.

If `dma_main` is already correct here, no source change needed; just verify and document.

### 4. Document the new slice contract in the `.deb` README / man page

A one-paragraph note that `dma-ethercat.service` is **not self-contained**: it relies on a host-side `/etc/systemd/system/<partition>.slice` and a `/etc/systemd/system/dma-ethercat.service.d/10-slice.conf` drop-in to place itself into the correct cgroup. Operators bringing up a host without `Phantom-OS-KubernetesOptions` bootstrap need to hand-write both, e.g.:

```ini
# /etc/systemd/system/dma-rt.slice
[Slice]
AllowedCPUs=11-13

# /etc/systemd/system/dma-ethercat.service.d/10-slice.conf
[Service]
CPUAffinity=
Slice=dma-rt.slice
```

(Slice name is operator's choice; bootstrap derives it from `cpuIsolation.partitions[].name`.)

## What we'd see in code review

A `.deb` PR with roughly:

- `debian/dma-ethercat.service` — drop the `/usr/bin/taskset -c ${DMA_CPU_AFFINITY}` prefix from `ExecStart`
- `debian/dma-ethercat.env` — remove the `DMA_CPU_AFFINITY=` line (Option 2a) or convert it to a comment (Option 2b)
- `README.md` / `docs/installation.md` — add the "slice contract" paragraph
- Bump package version (e.g. `V-1-0-5`) so existing fielded robots that run bootstrap will pick up the new unit

## What bootstrap should do once the `.deb` lands

In `Phantom-OS-KubernetesOptions` (separate PR, **not in this FIR-316**):

- `scripts/bootstrap-robot.sh` — `configure_dma_ethercat_env` stops writing `DMA_CPU_AFFINITY=` if Option 2a is taken. The slice file already handles cgroup placement.
- No change needed to the slice render or drop-in render — both are unchanged.

This is a **one-way migration**: once the `.deb` ships without `taskset` in ExecStart, the slice + drop-in becomes the only mechanism keeping dma-ethercat off housekeeping cpus. The pre-existing bootstrap (without FIR-318) would no longer work — confirming that FIR-318 must land in `Phantom-OS-KubernetesOptions` before the new `.deb` ships.

## Migration sequence (suggested)

1. Land FIR-316 + FIR-318 in `Phantom-OS-KubernetesOptions` → robots bootstrap with slice + drop-in, dma-ethercat works under current `.deb` (idempotent `taskset` no-op).
2. Land `.deb V-1-0-5` with the changes above → robots that re-bootstrap pick up the new `.deb`; the slice + drop-in already in place make it just work.
3. Drop `DMA_CPU_AFFINITY` writes from bootstrap → cleanup, optional, low priority.

No flag day, no fielded-robot disruption.
