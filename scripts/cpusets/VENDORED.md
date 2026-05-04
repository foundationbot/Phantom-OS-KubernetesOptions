# Vendored from DMA.ethercat

`manage_cpusets.sh`, the `lib/` shell modules, and `CPUSETS.md` in this
directory are a fork of upstream DMA.ethercat. The runbook at
[../../docs/cpu-isolation.md](../../docs/cpu-isolation.md) is a fork of
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
