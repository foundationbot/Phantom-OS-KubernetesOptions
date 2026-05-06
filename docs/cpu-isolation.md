# CPU Isolation & EtherCAT RT Setup

End-to-end procedure to (1) carve isolated cpuset partitions out of the
running kernel, (2) pin the EtherCAT NIC's IRQs onto them, (3) make the
setup survive reboots, and (4) drop the legacy `isolcpus=` kernel cmdline
in favour of cgroup-v2 cpuset partitions.

The companion reference doc is `scripts/cpusets/CPUSETS.md` (architecture, library
internals, verification phases). This file is the runbook.

> **Two ways to run this**
>
> - **Hands-on (this runbook):** invoke `scripts/cpusets/manage_cpusets.sh`
>   directly. Covers debugging, exploration, and one-off changes.
> - **Bootstrap-driven (default-on):** `bootstrap-robot.sh` phase 8
>   (cpu-isolation) prompts the operator on first bringup if no
>   `cpuIsolation:` block exists in `/etc/phantomos/host-config.yaml`,
>   persists the answers, and drives every subcommand non-interactively
>   on subsequent runs. See
>   [the Bootstrap-driven setup](#bootstrap-driven-setup) section near
>   the end of this file. Phase 8 gates phase 9 (install dma-ethercat)
>   so the .deb's systemd unit comes up with the partition already active.

---

## What this procedure produces

After completing every step and rebooting:

- A cpuset partition (default name `ecat`) covering the CPUs declared in
  `/etc/cpusets.conf`, activated automatically at boot via
  `cpusets.service`.
- The EtherCAT NIC's IRQs pinned to a single core inside that partition,
  ethtool low-latency tuning applied, governor locked to `performance`
  on every isolated core, unbound kernel workqueues restricted to
  housekeeping cores. Persisted via a separate boot service installed by
  `ethercat-rt`.
- `/etc/systemd/system.conf.d/cpuaffinity.conf` keeping every
  systemd-spawned service off the isolated cores by default.
- A kernel cmdline with `isolcpus=` removed and `rcu_nocb_poll`,
  `skew_tick=1`, `irqaffinity=<housekeeping>` added.

Two systemd services exist after install — they are independent:
- `cpusets.service` — activates partitions before docker / user@ / logind.
- A NIC RT-tuning service (name depends on iface) — pins IRQs and
  applies tuning at boot.

---

## Prerequisites

```bash
# cgroup v2 must be the only hierarchy
mount | grep cgroup2

# Kernel >= 5.4
uname -r

# The EtherCAT NIC must already exist as a Linux interface and be UP
ip -br link | grep '^ecat'
```

If no `ecat*` interface is present, run `setup_ethercat_interface.sh`
from the upstream DMA.ethercat repo (not vendored here) first to create
one — it writes the udev rules that rename the adapter.

---

## Step 0 — Write `/etc/cpusets.conf`

The `apply` and `install-service` subcommands require this file to exist.
The script does **not** generate it for you.

Minimum single-partition config (matches the cores currently isolated via
`isolcpus=10-13` on Thor):

```ini
[ecat]
cpus = 10-13
description = EtherCAT master RT loop
```

Multi-partition example (split RT cores into independent domains):

```ini
[ecat]
cpus = 10-11
description = EtherCAT master

[control]
cpus = 12

[vision]
cpus = 13
```

Constraints enforced by `apply`:
- Section names must be alphanumeric / underscore.
- `cpus = <range>` is required per section. Range syntax matches the
  kernel: `10-11`, `10,12`, `10-11,13`.
- At least 2 housekeeping (un-isolated) CPUs must remain. The script
  refuses configs that violate this.
- No two sections may overlap on the same CPU.

Write the file as root:

```bash
sudo install -m 0644 /dev/stdin /etc/cpusets.conf <<'EOF'
[ecat]
cpus = 10-13
description = EtherCAT master RT loop
EOF
```

---

## Step 1 — Apply at runtime

Creates the partitions immediately, without persisting across reboot. Use
this to confirm the config is valid and the partitions activate cleanly
before installing the boot service.

```bash
sudo ./scripts/cpusets/manage_cpusets.sh apply /etc/cpusets.conf
sudo ./scripts/cpusets/manage_cpusets.sh verify ecat
sudo ./scripts/cpusets/manage_cpusets.sh list
```

What `apply` does: parses the INI in two passes (validate → mutate),
shrinks `system.slice` / `user.slice` / `init.scope` / `docker.slice`
onto the housekeeping cores, then activates each partition by writing
`isolated` to `cpuset.cpus.partition`. Already-active partitions with
matching CPUs are skipped (idempotent).

What `verify <name>` checks (manage_cpusets.sh:706):
- Phase 0: cgroup v2 mounted, cpuset controller present.
- Phase 1/2: partition state is `isolated`, effective CPUs match
  requested, sibling slices don't claim the partition's CPUs.
- Phase 3: no unexpected userspace tasks on isolated cores.
- Phase 3.5: systemd affinity drop-in present (only if Step 3 ran).

If `apply` fails citing a sibling slice (typically `docker.slice`)
claiming the CPUs, the failure message names the specific slice. Stop
docker (`systemctl stop docker`) and retry, or proceed to Step 3 first
so the boot service ordering takes care of it on the next reboot.

---

## Step 2 — Pin the EtherCAT NIC IRQs (interactive)

```bash
sudo ./scripts/cpusets/manage_cpusets.sh ethercat-rt ecat --nic ecat1
```

`--nic` defaults to `ecat0`; pass the actual interface name shown by
`ip -br link`. This step **prompts** for confirmation when picking the RT
core inside the partition (`select_rt_core` at manage_cpusets.sh:682),
so do not pipe stdin or run it under nohup.

What it does (manage_cpusets.sh:648–702):
1. Restricts core-selection candidates to the partition's CPUs.
2. Discovers the NIC's IRQs and pins them to the chosen core.
3. Applies ethtool low-latency tuning (100M/full-duplex, no autoneg,
   coalescing off, offloads off, small rings, `napi_defer_hard_irqs` on).
4. Installs a NIC-tuning boot service so the tuning re-applies after
   reboot or link flap.
5. Locks `cpufreq` governor to `performance` on every isolated core.
6. Restricts unbound kernel workqueues to housekeeping cores.

Run `ethercat-rt` once per partition that needs a NIC. There is no
batch form of this subcommand.

---

## Step 3 — Install boot persistence

```bash
sudo ./scripts/cpusets/manage_cpusets.sh install-service /etc/cpusets.conf
sudo ./scripts/cpusets/manage_cpusets.sh install-affinity-defaults
sudo systemctl daemon-reexec
```

`install-service` (manage_cpusets.sh:838):
- Copies `manage_cpusets.sh` and `lib/*.sh` to
  `/usr/local/lib/manage_cpusets/` so the service is self-contained
  and survives the source tree moving.
- Copies `/etc/cpusets.conf` to its canonical path (idempotent if you
  passed that path).
- Drops a wrapper at `/usr/local/sbin/apply-cpusets`.
- Installs `cpusets.service` ordered `Before=docker.service
  user@.service systemd-logind.service` so those slices cannot claim
  the isolated CPUs before the partition activates.
- Prints a warning that `install-affinity-defaults` is a separate step.
  The script deliberately does not chain these.

`install-affinity-defaults` (manage_cpusets.sh:824):
- Computes the housekeeping CPU list (all online CPUs minus partitioned
  ones) and writes `/etc/systemd/system.conf.d/cpuaffinity.conf` with
  `[Manager] CPUAffinity=<housekeeping>`.
- Refuses to write an empty list.

`daemon-reexec`: required for the affinity drop-in to take effect on
services started before this step. Without it, the drop-in only applies
to services started after the next reboot.

---

## Step 4 — Migrate the kernel cmdline (interactive)

```bash
sudo ./scripts/cpusets/manage_cpusets.sh migrate-cmdline --add-rt-flags
```

What it does (manage_cpusets.sh:875):
- Detects bootloader: `/boot/extlinux/extlinux.conf` (Jetson) or
  `/etc/default/grub` (x86 GRUB). Errors out if neither is present.
- Backs up the config to `<path>.bak.<timestamp>`.
- Removes every `isolcpus=<…>` token from the cmdline.
- With `--add-rt-flags`: also injects `rcu_nocb_poll`, `skew_tick=1`,
  and `irqaffinity=<housekeeping>` (computed from current partitions).
  Existing values for any of these keys are stripped first so the
  replacement is clean.
- Prints the proposed diff and **prompts** before writing.
- For GRUB, runs `update-grub` after writing.

`--yes` skips the confirmation prompt. Do not pass it on the first run —
read the diff first.

**Recovery if the new cmdline does not boot.** The backup path is
printed by the script. On Jetson, restoring it requires booting from
recovery media or editing the eMMC/NVMe image from another host. There
is no in-place rollback after the `reboot` if the system fails to come
up — eyeball the diff carefully.

---

## Step 5 — Reboot

```bash
sudo reboot
```

Required for:
- The new kernel cmdline (`isolcpus=` removed, RT flags added).
- `cpuaffinity.conf` to apply to services that were started before
  Step 3's `daemon-reexec`.

On Jetson Thor, expect 30–60 s to come back.

---

## Step 6 — Verify after reboot

Read-only checks. Run these to confirm the system came up clean:

```bash
# Service active
systemctl status cpusets.service
journalctl -u cpusets.service -b      # no "CPUs not exclusive" errors

# Partitions match config
sudo ./scripts/cpusets/manage_cpusets.sh list
sudo ./scripts/cpusets/manage_cpusets.sh verify
sudo ./scripts/cpusets/manage_cpusets.sh status

# Kernel cmdline migrated
cat /proc/cmdline                     # must NOT contain isolcpus=
                                       # must contain rcu_nocb_poll, skew_tick=1, irqaffinity=

# Sysfs reflects the partition
cat /sys/devices/system/cpu/isolated  # matches your config CPUs

# NIC IRQs landed on the RT core
grep ecat1 /proc/interrupts           # IRQ counts only on the pinned core
                                       # (use the actual iface name)

# Optional: latency under load (requires rt-tests + stress-ng)
stress-ng --cpu 10 --taskset 0-9 --timeout 60s &
sudo ./scripts/cpusets/manage_cpusets.sh run ecat -- \
    cyclictest -p 95 -t 1 -a 13 -i 200 -l 1000000 -q
# Pass: max < 20 µs on Thor with all three layers active.
```

---

## What is and is not automated

The script does **not** provide a single-command "do everything"
subcommand. The honest layout:

| Combined? | Subcommand | What it skips |
|---|---|---|
| Yes | `create <name> <cpus> --with-ethercat-rt --nic <iface>` | Combines `create` + `ethercat-rt`. Single-partition path only. Does **not** install boot persistence or migrate the cmdline. |
| No | `apply <config>` | Has no `--with-ethercat-rt` equivalent. Run `ethercat-rt` separately for each partition that needs a NIC. |
| No | `install-service` | Deliberately does not run `install-affinity-defaults`; prints a warning telling you to run it. |
| No | `migrate-cmdline` | Does not install services or chain into reboot. |

If you only have one partition and one NIC, the procedure collapses
slightly:

```bash
# Replaces Steps 1 + 2:
sudo ./scripts/cpusets/manage_cpusets.sh create ecat 10-13 --with-ethercat-rt --nic ecat1
# Steps 3, 4, 5 still required separately.
```

For config-file-driven setups (Step 0's INI), the five steps stay as
five steps.

---

## Rollback

```bash
# Reverse, in opposite order:
sudo ./scripts/cpusets/manage_cpusets.sh uninstall-affinity-defaults
sudo ./scripts/cpusets/manage_cpusets.sh uninstall-service
# To revert the cmdline: restore the timestamped backup printed by
# migrate-cmdline (extlinux: /boot/extlinux/extlinux.conf.bak.<ts>;
# grub: /etc/default/grub.bak.<ts> followed by update-grub).
sudo systemctl daemon-reexec
sudo reboot
```

The NIC RT-tuning service installed by `ethercat-rt` is removed via
`the upstream DMA.ethercat repo (scripts/setup_ethercat_interface.sh — not vendored here)` (or by hand —
`systemctl disable --now <ecat-tuning-service>` and delete the unit
file under `/etc/systemd/system/`).

---

## Bootstrap-driven setup

`bootstrap-robot.sh` phase 8 (`cpu-isolation`) drives every subcommand
above non-interactively, reading `cpuIsolation:` from
`/etc/phantomos/host-config.yaml`. Phase 8 gates phase 9
(`install-dma-ethercat`) so the .deb's `dma-ethercat.service` unit is
started with the partition already active.

**Default-on.** If the block is absent and bootstrap runs on a TTY,
the operator is prompted for partition cpus, name, NIC iface, RT core,
affinity-drop-in, and cmdline-migration; answers persist back to
`host-config.yaml`. Re-runs are non-interactive. Pass
`--skip-cpu-isolation` to bypass for one run, or set
`cpuIsolation.enabled: false` to opt out persistently.

### Schema

```yaml
cpuIsolation:
  enabled: true
  partitions:
    - {name: ecat, cpus: "10-13", description: "EtherCAT master RT loop"}
  nic:                          # optional — only when this host pins a NIC
    iface: ecat0
    irqCore: 12                 # NIC IRQs / NAPI / softirq handling
    selector:                   # optional — drives phase 7 ecat-interface
      mac: aa:bb:cc:dd:ee:ff    # OR pci: "0000:01:00.0"
                                # OR {driver: igc, index: 0}
  dmaRtCpu: 11                  # SOEM cyclic loop (DMA_RT_CPU)
  installAffinityDefaults: true # default: true. Writes /etc/systemd/system.conf.d/cpuaffinity.conf.
  migrateCmdline: false         # default: false. DESTRUCTIVE on Jetson.
```

`cpuIsolation.nic.selector` is consumed by **phase 7 (ecat-interface)**,
which renames the NIC adapter to `nic.iface` via persistent udev rules
(`/etc/udev/rules.d/70-ecat.rules`). On a TTY first bringup the
operator can omit `selector` and let the vendored
`setup_ethercat_interface.sh` drive its interactive picker; on
re-runs and unattended bootstraps, fill in `selector` so the phase
runs non-interactively. Phase 7 is idempotent: if `ip link show <iface>`
already succeeds, it short-circuits without touching udev.

The full schema (with validation rules) lives at
[`host-config-templates/_template/host-config.yaml`](../host-config-templates/_template/host-config.yaml).

### Why irqCore and dmaRtCpu should differ

Async NIC interrupts (link blips, broadcasts, ARP) can land at any
moment. When the IRQ handler and the cyclic loop share a core, those
events can preempt the loop in the wrong microsecond — fine on average,
ugly in the p99.9 tail. The IgH EtherCAT documentation makes the same
point: hardware-IRQ-driven RX is asynchronous and indeterministic, so
keeping the cyclic path on a "no surprises" core matters for hard-RT.

The interactive prompt picks two distinct defaults from the partition
(first cpu for IRQs, second for the loop). The validator warns —
doesn't error — if you set them equal so you can deliberately co-locate
on hosts where average latency matters more than worst-case jitter
(e.g. soft-RT EtherCAT, or a 1-cpu partition where you have no choice).

The legacy `nic.rtCore` field is still accepted (with a deprecation
warning) and treated as `irqCore`. New configs should use the split
fields.

### What phase 8 does

1. Validates cgroup v2 is mounted.
2. Renders `/etc/cpusets.conf` from `cpuIsolation.partitions`.
3. `manage_cpusets.sh apply --yes` (idempotent — skips matching state).
4. `manage_cpusets.sh install-service` (boot persistence).
5. `manage_cpusets.sh install-affinity-defaults` + `daemon-reexec`
   (skipped only when `installAffinityDefaults: false`).
6. If `cpuIsolation.nic` is set:
   `manage_cpusets.sh ethercat-rt <partition> --nic <iface> --rt-core <N>`
   (the `--rt-core` flag is a Phantom-OS local addition — see
   [`scripts/cpusets/VENDORED.md`](../scripts/cpusets/VENDORED.md)).
7. If `migrateCmdline: true`:
   `manage_cpusets.sh migrate-cmdline --add-rt-flags --yes`, then drop
   `/etc/phantomos/cpu-isolation.reboot-pending` so the operator
   knows a reboot is needed.

### Skipping the phase

`--skip-cpu-isolation` opts out for one bootstrap run (e.g. when
debugging another phase). To turn it off persistently, set
`cpuIsolation.enabled: false` (or omit the block entirely) in
`host-config.yaml`.

### Interaction with k0s/kubelet

k0s starts kubelet which creates a `kubepods` (cgroupfs) or
`kubepods.slice` (systemd) cgroup covering every CPU at startup.
Without ordering, this cgroup claims the cores you want isolated and
the partition fails to activate (`isolated invalid (Cpu list in
cpuset.cpus not exclusive)`).

Phase 8 handles this two ways:

- The vendored `manage_cpusets.sh` lists `kubepods` and
  `kubepods.slice` in `MANAGED_SLICES`, so its runtime shrink step
  trims kubelet's root cgroup to the housekeeping cores before
  activating the partition.
- The installed `cpusets.service` is ordered
  `Before=k0scontroller.service k0sworker.service` so on every
  subsequent reboot, partitions activate before kubelet starts and
  kubepods is created with isolation already in place.

If you bootstrap with `migrateCmdline: false` and a stale
`isolcpus=10-13` is still on the kernel cmdline, the cpuset partition
still works but the legacy mechanism is redundant — you cannot
dynamically release the cores. Set `migrateCmdline: true` once on
production robots to clean it up; reboot is required.

### Re-runs

Phase 8 is idempotent. The vendored `manage_cpusets.sh apply` skips
already-active partitions whose CPUs match the config. Re-bootstrapping
after editing `cpuIsolation.partitions` will tear down and recreate
only the partitions whose CPUs changed.

The reboot-pending marker is auto-cleared on the next bootstrap that
sees a clean kernel cmdline (`isolcpus=` absent).
