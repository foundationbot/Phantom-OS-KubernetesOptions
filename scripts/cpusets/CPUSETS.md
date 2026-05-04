# CPU Isolation & EtherCAT RT Tooling

Two CLI tools backed by a shared shell library for real-time CPU isolation
and EtherCAT NIC setup on Jetson Thor (applies to any Linux host with cgroup
v2).

> Looking for the runbook? See
> [`docs/cpu-isolation.md`](../../docs/cpu-isolation.md) for the
> step-by-step setup procedure (write config → apply → pin NIC →
> install boot service → migrate cmdline → reboot). This file is the
> reference doc covering subcommands, library internals, and the
> verification phases.

```
scripts/
├── lib/
│   ├── cpu_utils.sh         # CPU list parsing, set ops, isolation detection
│   ├── nic_rt.sh            # NIC detection, IRQ pinning, ethtool tuning
│   └── systemd_units.sh     # Service + drop-in writers
├── setup_ethercat_interface.sh   # (NOT vendored — see DMA.ethercat upstream)   # Interactive EtherCAT NIC setup
└── manage_cpusets.sh              # cgroup v2 cpuset partition manager
```

## Concepts

Two complementary mechanisms isolate CPUs from the default scheduler:

- **`isolcpus=`** (kernel cmdline) — static, decided at boot. Legacy.
- **`cpuset.cpus.partition=isolated`** (cgroup v2) — dynamic, can be created
  and torn down at runtime. Modern.

Both populate `/sys/devices/system/cpu/isolated` so the two tools in this
tree work with either mechanism. The new `manage_cpusets.sh` is the
replacement for `isolcpus=` when you want multiple independent isolated
domains or runtime flexibility.

For full isolation you need **all three** layers:

| Layer | What it blocks | Mechanism |
|---|---|---|
| sched-domain isolation | Scheduler load-balancing across isolated cores | `isolcpus=` or cpuset partition |
| default process affinity | systemd-spawned services starting on isolated cores | `/etc/systemd/system.conf.d/cpuaffinity.conf` |
| IRQ affinity | Interrupts landing on isolated cores | `irqaffinity=` cmdline + `/proc/irq/*/smp_affinity` |

`manage_cpusets.sh` handles layers 1 and 2. `setup_ethercat_interface.sh   # (NOT vendored — see DMA.ethercat upstream)`
handles layer 3 for a specific NIC.

## `manage_cpusets.sh` — cpuset partition manager

### Subcommands

| Subcommand | Purpose |
|---|---|
| `create <name> <cpus> [--with-ethercat-rt] [--nic <iface>]` | Create an isolated partition |
| `remove <name>` | Tear down a partition |
| `list` | List partitions managed by this tool |
| `status` | Global isolation state (cmdline + sysfs + drop-in + service) |
| `run <name> -- <cmd...>` | Run a command pinned inside a partition |
| `apply <config-file> [--yes]` | Batch-create partitions from an INI file |
| `verify [<name>]` | Run the verification suite (phases 0, 1/2, 3, 3.5) |
| `ethercat-rt <name> [--nic <iface>]` | Pin NIC IRQs onto a partition's cores |
| `install-service <config-file>` | Install boot-time service |
| `uninstall-service` | Reverse of install-service |
| `install-affinity-defaults` | Write `/etc/systemd/system.conf.d/cpuaffinity.conf` |
| `uninstall-affinity-defaults` | Reverse of install-affinity-defaults |
| `migrate-cmdline [--add-rt-flags]` | Remove `isolcpus=` from the kernel cmdline |
| `status`, `help` | |

### Single-partition quickstart

```bash
# Create a partition on CPU 13
sudo ./manage_cpusets.sh create rt 13
sudo ./manage_cpusets.sh verify rt

# Run a workload inside it
sudo ./manage_cpusets.sh run rt -- ./my_rt_program

# Later
sudo ./manage_cpusets.sh remove rt
```

### Multi-partition example

```bash
sudo ./manage_cpusets.sh create ecat    10-11
sudo ./manage_cpusets.sh create vision  12
sudo ./manage_cpusets.sh create control 13
sudo ./manage_cpusets.sh list
```

Or via config file (`/etc/cpusets.conf`):

```ini
[ecat]
cpus = 10-11
description = EtherCAT master RT loop

[vision]
cpus = 12
description = Vision pipeline

[control]
cpus = 13
description = High-rate control loop
```

```bash
sudo ./manage_cpusets.sh apply /etc/cpusets.conf
```

### Boot persistence

```bash
sudo ./manage_cpusets.sh install-service /etc/cpusets.conf
sudo ./manage_cpusets.sh install-affinity-defaults     # optional but recommended
sudo systemctl daemon-reexec                           # pick up affinity drop-in
```

`install-service` copies the scripts and libraries to
`/usr/local/lib/manage_cpusets/` so the service is self-contained at runtime
and does not depend on the source tree remaining in place. The cpusets
service is ordered **before** `docker.service`, `user@.service`, and
`systemd-logind.service` so their cgroups don't claim the CPUs you're
trying to isolate.

### Migrating from `isolcpus=` to cpuset partitions

`isolcpus=` and cpuset partitions can coexist, but keeping `isolcpus=`
means the isolated CPUs can't be dynamically released. To migrate:

```bash
# 1. Install the boot service so partitions come up at next boot
sudo ./manage_cpusets.sh install-service /etc/cpusets.conf
sudo ./manage_cpusets.sh install-affinity-defaults

# 2. Remove isolcpus= from the kernel cmdline (adds recommended RT flags)
sudo ./manage_cpusets.sh migrate-cmdline --add-rt-flags

# 3. Reboot
sudo reboot
```

The `migrate-cmdline` subcommand detects `/boot/extlinux/extlinux.conf`
(Jetson) or `/etc/default/grub` (GRUB), makes a timestamped backup, shows
the diff, and applies atomically after confirmation.

### Preflight checks

Every write operation runs:

1. `cgroup v2 mounted, cpuset controller present, subtree_control includes cpuset`
2. `requested CPUs are online`
3. `no overlap with other managed partitions`
4. `housekeeping floor respected` (at least 2 CPUs remain un-isolated)
5. `isolcpus= overlap check` with interactive prompt to continue, abort for
   migrate, or abort to pick different CPUs

### Failure diagnosis

When a partition fails to activate, the tool reads
`cpuset.cpus.partition` for the reason, then walks every sibling cgroup and
names the specific one still claiming the requested CPUs. This turns the
opaque "isolated invalid (Non-exclusive cpuset)" error into
"`docker.slice` claims `0-13` (overlap: `10-11`)".

## `setup_ethercat_interface.sh   # (NOT vendored — see DMA.ethercat upstream)` — EtherCAT NIC setup

Same CLI as before. No behavioural changes for existing users beyond the
following improvements (all via the extracted libraries):

- `pin_irqs_to_core` surfaces driver-managed IRQs with an actionable hint
  ("fix via driver module params or `ethtool -L <iface> combined N`")
- `apply_nic_tuning` comment on `napi_defer_hard_irqs` matches the actual
  behaviour (enables deferral, doesn't disable busy polling)
- `select_rt_core` now requires an explicit confirmation before using a
  non-isolated core and suggests the cpuset alternative
- `check_kernel_params` accepts cpuset-based isolation as equivalent to
  `isolcpus=` (no longer complains when isolation is done via cpuset)
- `check_kernel_params` also checks `irqaffinity=`
- The generated boot service additionally locks the performance governor on
  every isolated core and restricts unbound kernel workqueues to
  housekeeping cores

### Integration with `manage_cpusets.sh`

After creating a partition, bind NIC IRQs onto its cores in one step:

```bash
# Option A: create + ethercat-rt in a single invocation
sudo ./manage_cpusets.sh create ecat 10-11 --with-ethercat-rt --nic ecat0

# Option B: chain explicitly
sudo ./manage_cpusets.sh create ecat 10-11
sudo ./manage_cpusets.sh ethercat-rt ecat --nic ecat0
```

The `ethercat-rt` subcommand pre-scopes `select_rt_core` to the partition's
cores so you pick an IRQ-pinned core from within the partition instead of
from the full set of isolated cores.

## Verification plan

Run `manage_cpusets.sh verify [<partition>]` to exercise phases 0 through
3.5 automatically. Phases 4–7 below are manual or script-driven separately.

### Phase 0 — Environment preconditions

- [ ] `mount | grep cgroup2` shows cgroup v2 at `/sys/fs/cgroup`
- [ ] `cat /sys/fs/cgroup/cgroup.controllers` includes `cpuset`
- [ ] `cat /sys/fs/cgroup/cgroup.subtree_control` includes `cpuset` (auto-fixed)
- [ ] `uname -r` is 5.4 or newer

### Phase 1 — Single partition lifecycle

1. `create test1 13` → success
2. `cat /sys/fs/cgroup/test1/cpuset.cpus.partition` → `isolated`
3. `/sys/devices/system/cpu/isolated` contains 13
4. `/sys/fs/cgroup/system.slice/cpuset.cpus.effective` does not contain 13
5. `remove test1` → cgroup gone, isolated set shrinks

### Phase 2 — Multi-partition integrity

1. `create a 10-11`, `create b 12`, `create c 13` → all succeed
2. `create d 11` → fails with overlap error naming partition `a`
3. `create d 99` → fails (offline CPU)

### Phase 3 — Task placement

1. `create rt 13`
2. `run rt -- sleep 300 &`
3. `cat /proc/<pid>/status | grep Cpus_allowed_list` → `13`
4. `ps -eo psr,comm | awk '$1==13'` → only the sleep (+ acceptable kernel
   threads: `migration/13`, `ksoftirqd/13`, `cpuhp/13`, `rcu*`, `kworker*`)

### Phase 3.5 — systemd affinity drop-in

1. `install-affinity-defaults`
2. `systemctl daemon-reexec`
3. `systemd-run --unit=test /bin/sleep 300`
4. `cat /proc/$(pgrep sleep)/status | grep Cpus_allowed_list` → housekeeping
   range, not `0-13`

### Phase 4 — Isolation quality under load

Requires `rt-tests` (`apt install rt-tests`) and `stress-ng`.

Baseline:
```bash
cyclictest -p 95 -t 1 -a 13 -i 200 -l 1000000 -q
```

Under stress on housekeeping cores:
```bash
stress-ng --cpu 10 --taskset 0-9 --timeout 60s &
manage_cpusets.sh run rt -- cyclictest -p 95 -t 1 -a 13 -i 200 -l 1000000 -q
```

Pass criterion: max latency < 20 µs on Thor with `nohz_full` + `rcu_nocbs` +
governor locked. Higher values usually mean a service started before the
partition — check ordering in `install-service` logs.

### Phase 5 — Boot persistence

1. `install-service /etc/cpusets.conf`
2. `systemctl status cpusets.service` → active (exited)
3. `reboot`
4. After reboot: `list` matches config; `cat /sys/devices/system/cpu/isolated`
   matches
5. `journalctl -u cpusets.service -b` — no "CPUs not exclusive" errors

### Phase 6 — Failure-mode diagnostics

Deliberately trigger errors to confirm the tool surfaces them:

1. Create partition, then manually `echo member > .../cpuset.cpus.partition`.
   `verify <name>` should flag partition-not-active.
2. Start docker before partition creation. `create` should name
   `docker.slice` as the conflicting claimant.
3. Request a partition covering all cores. `create` should refuse citing
   the housekeeping floor.
4. Request overlapping partition. `create` should refuse and name the
   conflict.

### Phase 7 — Cleanup

1. `uninstall-service` → service disabled, `/usr/local/lib/manage_cpusets`
   removed
2. Remove all partitions
3. `cat /sys/fs/cgroup/system.slice/cpuset.cpus` back to full range
4. No orphan directories under `/sys/fs/cgroup`

## Library internals

### `lib/cpu_utils.sh`

Pure-function utilities. No side effects. Safe to source independently.

Key functions:

- `expand_cpu_range "10-11,13"` → `10 11 13`
- `compress_cpu_list "10 11 12 13"` → `10-13`
- `cpu_list_union A B`, `cpu_list_intersect A B`, `cpu_list_diff A B`
- `cpu_list_to_hex_mask "0-9"` → `3ff`
- `detect_isolated_cores` — works for both `isolcpus=` and cpuset partitions
- `parse_isolcpus_cmdline`, `parse_nohz_full_cmdline`, `parse_rcu_nocbs_cmdline`,
  `parse_irqaffinity_cmdline`
- `compute_housekeeping_list`, `compute_housekeeping_mask`

### `lib/nic_rt.sh`

NIC-centric operations. Sources `cpu_utils.sh`.

- Adapter detection into `USB_ADAPTERS` / `NATIVE_ADAPTERS` arrays
- Udev rule writers (USB vendor:product, or MAC address)
- `find_nic_irqs`, `pin_irqs_to_core`, `configure_irqbalance`
- `apply_nic_tuning`, `emit_nic_tuning_snippet` (used by systemd units lib)
- `create_nic_tuning_dispatcher`, `remove_nic_tuning_dispatcher`
- `select_rt_core` — respects `RT_CANDIDATE_CORES` to scope to a partition
- `check_kernel_params` — dual-mode (isolcpus or cpuset)
- `lock_isolated_core_governors`, `restrict_workqueue_mask`

### `lib/systemd_units.sh`

Writers for all systemd files in the tree:

- `write_ethercat_rt_service` — generates self-contained boot script (no
  runtime source dependency)
- `write_cpusets_service` — copies source tree to `/usr/local/lib/manage_cpusets`
  and installs wrapper + unit
- `write_affinity_drop_in` — `/etc/systemd/system.conf.d/cpuaffinity.conf`
- Matching removers

## Requirements

- Linux kernel ≥ 5.4 (cgroup v2 cpuset partitions)
- `bash` (the libraries rely on bash-specific behaviour)
- `systemd` (for service installation and affinity drop-in)
- Optional: `networkd-dispatcher` (for NIC tuning persistence),
  `rt-tests` (for Phase 4 verification), `stress-ng` (same)
