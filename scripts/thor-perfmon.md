# thor-perfmon

Single-file Python tool that records a comprehensive system performance trace
on a Jetson Thor robot while the operator runs their application in another
shell. Outputs a CSV (one row per sample) plus a 6-panel matplotlib PNG
(CPU breakdown, GPU+EMC+temp, memory components, faults/ctx-sw, disk I/O,
cache misses + power).

Stdlib + `tegrastats` + (optional) `perf` + (optional) `matplotlib`. No other
deps. One file — `scp` it anywhere and run.

## Where it lives

Pre-installed at `/usr/local/bin/thor-perfmon.py` on:

- `mk11000009`
- `hw-thor01`

The script is standalone — `scp` it onto any Jetson Thor box and run it
directly. `tegrastats` must be on `PATH`, otherwise it exits immediately.

## Sources of truth

| Metric group                           | Source                                                       |
|----------------------------------------|--------------------------------------------------------------|
| GPU (GR3D), EMC, RAM, junction temp,   | `tegrastats` (drives sample cadence)                         |
| VIN power, VDD\_GPU, per-core CPU MHz  |                                                              |
| CPU breakdown, ctx-switches, intr      | `/proc/stat` (deltas → percentages and per-second rates)     |
| Memory components                      | `/proc/meminfo`                                              |
| Page faults, swap activity             | `/proc/vmstat` (deltas → per-second rates)                   |
| Disk I/O                               | `/proc/diskstats` (sum across non-loop/non-ram, non-partition devices) |
| Load average                           | `/proc/loadavg`                                              |
| Cache misses, branch mispredicts, IPC  | `perf stat -a -I <ms>` (optional)                            |
| Per-process metrics                    | `/proc/<pid>/{stat,io,status}` (optional, `--pid`)            |

## CLI flags

| Flag             | Default | Meaning                                                                 |
|------------------|---------|-------------------------------------------------------------------------|
| `--duration`     | `300`   | Run length in seconds. `0` = until interrupted.                         |
| `--interval-ms`  | `1000`  | Sampling interval. Drives `tegrastats` and `perf stat`.                 |
| `--pid`          | unset   | Also capture per-process metrics for this PID.                          |
| `--out`          | auto    | Output prefix. Default `./perfmon_<host>_<YYYYMMDD-HHMMSS>`. CSV/PNG share this prefix. |
| `--no-plot`      | off     | Skip matplotlib at exit (useful headless / no matplotlib installed).    |
| `--no-perf`      | off     | Skip `perf stat` entirely (no cache-miss / branch-mispredict / IPC).    |
| `--quiet`        | off     | Suppress per-sample stdout summary line.                                |

## Caveat: perf and `kernel.perf_event_paranoid`

On both robots `kernel.perf_event_paranoid = 2`, which blocks system-wide
`perf stat -a`. Without intervention, system-wide runs will start `perf` but
get `<not supported>` for every counter, and the perf columns will simply be
absent from the CSV.

To enable system-wide perf counters:

```sh
sudo sysctl kernel.perf_event_paranoid=1   # cache, branch, IPC counters
sudo sysctl kernel.perf_event_paranoid=-1  # full access (cycles, kernel)
```

`--pid` scoping works at `paranoid=2` if the operator owns the target
process — no sysctl needed.

If you don't want to touch sysctl, run with `--no-perf` and the tool skips
those metrics gracefully.

## Examples

Default 5-min run on the robot:

```sh
sudo thor-perfmon.py
```

Time-boxed run with output prefix on `/root`:

```sh
sudo thor-perfmon.py --duration 120 --out /root/run1
# -> /root/run1.csv, /root/run1.png
```

Scope to `dma_main`:

```sh
sudo thor-perfmon.py --pid $(pidof dma_main) --duration 60
```

Headless / CSV-only on a host without matplotlib:

```sh
sudo thor-perfmon.py --no-plot --no-perf --out /tmp/quick
```

2 Hz sampling:

```sh
sudo thor-perfmon.py --interval-ms 500
```

## Output anatomy

### CSV

Header is locked from the first sample's keys (deterministic insertion
order, `ts` first). Subsequent rows fill missing keys with empty string.
File is flushed after every write so a `kill -9` still leaves a parseable
CSV up to the last completed sample.

Column reference (presence depends on flags / sysctl / availability):

- **Time**: `ts` (ISO-8601, ms precision, wall clock)
- **CPU %** (from `/proc/stat` deltas): `cpu_busy_pct`,
  `cpu_user_pct`, `cpu_system_pct`, `cpu_iowait_pct`, `cpu_idle_pct`,
  `cpu_irq_pct`, `cpu_softirq_pct`, plus `nice` / `steal`
- **Scheduler**: `ctxt_per_s`, `intr_per_s`, `forks_per_s`, `procs_running`,
  `load_1m`, `load_5m`, `load_15m`
- **Memory** (from `/proc/meminfo`, KB): `mem_total_kb`, `mem_used_kb`
  (= `total - available`), `mem_avail_kb`, `mem_free_kb`, `mem_anon_kb`,
  `mem_cached_kb`, `mem_buffers_kb`, `mem_slab_kb`, `mem_pagetables_kb`,
  `mem_dirty_kb`, `mem_writeback_kb`, `mem_active_kb`, `mem_inactive_kb`,
  `mem_mapped_kb`, `mem_shmem_kb`, `mem_sreclaim_kb`, `mem_swapcached_kb`,
  `swap_total_kb`, `swap_used_kb`, `swap_free_kb`
- **VM rates** (from `/proc/vmstat` deltas): `pgfault_per_s`,
  `pgmajfault_per_s`, `pgpgin_per_s`, `pgpgout_per_s`, `pswpin_per_s`,
  `pswpout_per_s`
- **Disk** (from `/proc/diskstats` deltas, summed across whole devices —
  partitions, loop, ramdisk excluded): `disk_read_kb_per_s`,
  `disk_write_kb_per_s`, `disk_read_ios_per_s`, `disk_write_ios_per_s`
- **Jetson** (from `tegrastats`): `gpu_pct` (mean across GPCs),
  `gpu_max_pct` (max GPC), `emc_pct`, `emc_mhz`, `tj_c`, `vin_mw`,
  `vdd_gpu_mw`, `tg_ram_used_mb`, `tg_ram_total_mb`, and per-core
  `tg_cpu<N>_pct` / `tg_cpu<N>_mhz`
- **perf** (when available): `perf_cycles`, `perf_instructions`,
  `perf_cache_references`, `perf_cache_misses`, `perf_branches`,
  `perf_branch_misses`, `perf_page_faults`, `perf_context_switches`
- **Per-pid** (only with `--pid`): `pid_state`, `pid_utime_jif`,
  `pid_stime_jif`, `pid_threads`, `pid_rss_pages`, plus per-second deltas
  `pid_io_rchar_per_s`, `pid_io_wchar_per_s`, `pid_io_read_bytes_per_s`,
  `pid_io_write_bytes_per_s`, `pid_ctxsw_vol_per_s`, `pid_ctxsw_invol_per_s`

### PNG (6 panels, 3×2 grid, shared X axis = elapsed seconds)

1. **CPU breakdown + load**: `cpu_busy_pct` (black), `cpu_user_pct`,
   `cpu_system_pct`, `cpu_iowait_pct`. Right axis: `load_1m`.
2. **GPU + EMC + temperature**: `gpu_pct`, `emc_pct`. Right axis: `tj_c`.
3. **Memory components (MB)**: anon, cached, buffers, slab, dirty.
   Dotted reference line at `mem_total_kb`.
4. **Faults / context switches**: `pgfault_per_s`, `pgmajfault_per_s`.
   Right axis: `ctxt_per_s`.
5. **Disk I/O**: `disk_read_kb_per_s`, `disk_write_kb_per_s` in MB/s.
   Right axis: `disk_read_ios_per_s`, `disk_write_ios_per_s` (IOPS).
6. **Cache + branch + power**: cache miss % (`perf_cache_misses /
   perf_cache_references`), branch miss %. Right axis: `vin_mw` in W.

### Stdout summary

Unless `--quiet`, each sample prints a one-liner like:

```
2026-05-05T14:02:11.483  cpu= 47.3%  gpu=22.0%  ram=31.4%  pgmaj/s=  0.0  rd=  0.0MB/s wr=  1.2MB/s  ctxt/s= 18432  tj=58.3C  vin= 28.41W
```

## Stop conditions

- `--duration` elapsed.
- `SIGINT` (Ctrl-C) or `SIGTERM` — handler terminates `tegrastats`,
  drains the loop, closes the CSV, and (unless `--no-plot`) renders the
  PNG from whatever was captured.
- `tegrastats` subprocess exits — main loop terminates because it iterates
  on `tegrastats` stdout.

The plot reads the CSV at the end, so a Ctrl-C mid-run still produces a
usable PNG.

## Interpreting the output

- High `cpu_iowait_pct` together with high `disk_*_kb_per_s` → I/O-bound.
  CPU isn't the bottleneck; storage is.
- `pgmajfault_per_s` rising relative to `pgfault_per_s` → working set
  exceeds physical RAM. Either swapping (check `pswpin_per_s` /
  `pswpout_per_s`) or hitting page-cache misses on file-backed pages.
- `perf_cache_misses / perf_cache_references` (panel 6) climbing while
  `cpu_busy_pct` and `gpu_pct` stay flat → memory-bandwidth-bound.
  Confirm with `emc_pct` near saturation.
- `gpu_max_pct` ≫ `gpu_pct` → uneven GPC utilization in CUDA work.
  One GPC pinned, others idle — likely a kernel launch / occupancy issue.
- `tj_c` near 90 °C → thermal throttle imminent (Thor TJ target ~90 °C).
  Expect `tg_cpu*_mhz` and `gpu_pct` to clip.
