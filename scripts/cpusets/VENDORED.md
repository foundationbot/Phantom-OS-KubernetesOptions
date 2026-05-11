# Vendored from DMA.ethercat

`manage_cpusets.sh`, the `lib/` shell modules, and `CPUSETS.md` in this
directory are a fork of upstream DMA.ethercat. The runbook at
[../../docs/internal/cpu-isolation.md](../../docs/internal/cpu-isolation.md) is a fork of
upstream `docs/CPUSETS_SETUP.md`.

| | |
|---|---|
| Upstream repo | `foundation/DMA/DMA.ethercat` |
| Forked at SHA | `fd854dabcbbaba864a16c9e42fda98dfe386ab6a` |
| Forked on | 2026-05-04 |

## Why a fork

Bootstrap concerns (idempotence on re-runs, dry-run support, fully
non-interactive defaults driven by `host-config.yaml`) will diverge
from the upstream interactive operator workflow. We accept the drift
rather than coupling bootstrap upgrade cadence to a sibling repo.

## Divergence policy

Local edits are encouraged when they make `bootstrap-robot.sh`
integration cleaner — e.g. adding non-interactive flags, JSON output,
or alternate config-file locations. Cherry-pick interesting changes
back upstream when they're broadly useful, but don't block bootstrap
work on upstream review.

There is no automated sync. To pull upstream fixes, manually diff and
merge — preserve any local patches noted at the top of each modified
file.

## `setup_ethercat_interface.sh`

`setup_ethercat_interface.sh` was vendored at the same upstream SHA
(`fd854dabcbbaba864a16c9e42fda98dfe386ab6a`) on 2026-05-04. It carries
the same divergence policy as the rest of the cpusets tree. Local
patches versus upstream:

- Adds a non-interactive selector path (`--iface`, `--mac`, `--pci`,
  `--driver`+`--index`, `--yes`) so the bootstrap phase can rename a
  NIC without operator input. The interactive flow is preserved
  byte-for-byte for first-bringup operators.
- Adds a new helper library `lib/nic_discovery.sh` with pure-shell
  selector functions (`nic_match_by_mac`, `nic_match_by_pci`,
  `nic_match_by_driver`, `nic_validate_iface_name`).
- Switches the udev rule path from `/etc/udev/rules.d/99-ethercat.rules`
  to `/etc/udev/rules.d/70-ecat.rules` so the rename rule fires before
  systemd's net.link rules at 80- and any persistent-net rules typically
  written at 75-/76-.
- Adds an idempotent fast-path: if the target iface already exists and
  the udev rule already names it, the script exits 0 without rewriting.
- Parameterises the previously hardcoded `ecat0` interface name via
  `--iface` so multi-NIC robots can host `ecat0`, `ecat1`, etc.
- Switches from `set -e` to `set -u` plus explicit `die()` error
  handling, matching the convention used by `manage_cpusets.sh` in this
  same directory.
