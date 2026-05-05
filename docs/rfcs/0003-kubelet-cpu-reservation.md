# RFC 0003 — Teach kubelet about isolated CPUs

**Status:** Draft
**JIRA:** FIR-282
**Author:** TBD
**Created:** 2026-05-04

## Problem

Phase 8 of `scripts/bootstrap-robot.sh` (`cpu-isolation`, see
[docs/cpu-isolation.md](../cpu-isolation.md)) activates a cgroup v2 cpuset
partition that pins the EtherCAT real-time loop to a dedicated set of cores
and shrinks every other slice — `system.slice`, `user.slice`, and now
`kubepods` / `kubepods.slice` — to a housekeeping subset. The runtime shrink
of `kubepods` (added in commit `d2a5865`, where `MANAGED_SLICES` was extended
to include `kubepods` and `kubepods.slice`) plus the `Before=k0scontroller.service
k0sworker.service` ordering on `cpusets.service` is enough to keep the kernel
cgroup state correct across reboots: when the host comes up, partitions are
applied before kubelet ever starts, so kubelet inherits a `kubepods` cgroup
that is already restricted to housekeeping CPUs.

That's the right thing at the kernel level. It is not the right thing at the
Kubernetes level. **kubelet itself still believes it owns every online CPU.**
Concretely:

- `Node.status.allocatable.cpu` advertises the full core count to the
  scheduler. Pods land on this node based on a CPU pool that is two-to-six
  cores larger than what kubelet can actually hand out.
- Kubelet's `CPUManager` state file at `/var/lib/kubelet/cpu_manager_state`
  records `0..N` as the assignable pool. With the default
  `cpuManagerPolicy=none` this is mostly cosmetic — kubelet doesn't pin pods
  to specific cores — but it is wrong, and any future switch to `static` will
  inherit the wrong assumption.
- A Guaranteed-QoS pod with integer `resources.requests.cpu` under
  `cpuManagerPolicy=static` will be assigned exclusive cores by kubelet's
  CPUManager. If kubelet picks an isolated core (say cpu 12 on a robot whose
  EtherCAT partition owns 11–13), the cgroup write at pod start fails because
  the parent `kubepods` cpuset doesn't contain that CPU. The pod fails opaquely
  at the runtime/CRI layer with a confusing error.
- A manual `systemctl restart k0scontroller` mid-life can re-write
  `kubepods/cpuset.cpus` back to all CPUs. The next reboot will heal it
  (cpusets.service runs `Before=` k0s), but until then the partition is
  effectively broken from kubelet's perspective.

The right fix is to make kubelet a first-class participant in the partition
contract: tell it at startup that some cores are reserved and not eligible
for pods. kubelet exposes this as `--reserved-cpus=<list>` paired with
`--cpu-manager-policy=static`. In a k0s deployment, those flags are surfaced
through `spec.workerProfiles[]` or `kubelet-extra-args`, depending on the
exact k0s API surface (see [Open questions](#open-questions)).

## Goals

1. Kubelet's `Node.status.allocatable.cpu` reports only housekeeping cores.
2. The kubelet `CPUManager` assignable pool excludes every CPU that appears
   in any `cpuIsolation.partitions[].cpus` entry.
3. Housekeeping cores are derived from the existing `cpuIsolation` schema —
   no new source of truth, no manual list of "reserved" CPUs.
4. Phase 3 (cluster) of `bootstrap-robot.sh` renders the kubelet config when
   it renders the k0s config; configuration does not drift between
   bootstrap runs.
5. The runtime cgroup shrink (today's behaviour, commit `d2a5865`) stays in
   place as belt-and-suspenders. Cgroup state remains the kernel-level
   source of truth; kubelet's view is a derived projection of it.
6. Existing in-life robots (currently running with `cpuManagerPolicy=none`
   and a wrong allocatable count) can migrate without an outage.
7. The migration path tolerates the fact that
   `/var/lib/kubelet/cpu_manager_state` is **immutable** for policy changes
   once it has been written.
8. Heterogeneous fleet members (different core counts, different partition
   layouts) are supported without per-robot manifest forks.

## Non-goals

- Kubelet's **memory manager** (`--memory-manager-policy`). Memory NUMA
  pinning is a sibling problem; track separately.
- Kubelet's **topology manager** (`--topology-manager-policy`). Same.
- CRI-level pinning (containerd's `cpu.shares` / `cpuset` rendering for
  individual containers). Solved upstream once kubelet's policy is right.
- Per-pod CPU placement DSLs. Pods continue to use vanilla
  `resources.requests.cpu` semantics.
- Re-architecting how cgroup partitions are activated. Phase 8 is shipped
  and works; this RFC composes with it.

## Current state

What's already shipped under FIR-269:

- `host-config-templates/_template/host-config.yaml` carries a
  `cpuIsolation:` block with `partitions[]`, each partition naming a list
  of `cpus`.
- `scripts/bootstrap-robot.sh` phase 8 reads that block and applies the
  partition via the vendored `scripts/cpusets/manage_cpusets.sh`.
- Commit `d2a5865` extended `MANAGED_SLICES` in `manage_cpusets.sh` to
  include `kubepods` and `kubepods.slice`. As a result, when phase 8 runs
  (at bootstrap time **or** on every boot via `cpusets.service`), the
  `kubepods` cgroup is shrunk to housekeeping cores.
- The installed `cpusets.service` is ordered `Before=k0scontroller.service
  k0sworker.service`. On reboot, partitions exist before kubelet starts,
  so the cgroup state kubelet inherits is already correct.

What's **not** done:

- Kubelet has no `--reserved-cpus` configured. Its allocatable pool and
  CPUManager state still claim every online CPU.
- The k0s rendering step in phase 3 does not consult `cpuIsolation`. The
  k0s config it writes is identical regardless of which cores the robot
  intends to isolate.
- There is no `kubelet:` block in the host-config schema.

## Options

### Option 1 — Shrink-only (status quo)

Keep what we have today. `MANAGED_SLICES` includes `kubepods*`, runtime
shrink trims kubelet's cgroup at partition-apply time, `cpusets.service`
runs before kubelet on boot.

**Pro:**
- Zero kubelet config changes.
- Works on every existing cluster without a kubelet restart.
- Unblocks the partition activation we needed for FIR-269.

**Con:**
- Kubelet's view of the world is wrong. `allocatable.cpu` advertises
  cores the pod scheduler cannot actually use.
- A Guaranteed-QoS pod with integer CPU requests under a future `static`
  policy will fail opaquely when kubelet picks a reserved core.
- A manual `systemctl restart k0scontroller` can transiently un-isolate
  until the next `cpusets.service` activation (boot, or manual
  invocation).
- No declarative hook for the operator to say "this node is RT-isolated"
  beyond reading the cpuset state.

**Effort:** Zero — this is what's deployed.

### Option 2 — `--reserved-cpus` via k0s `extraArgs`

Phase 3 renders the k0s config with a `kubelet-extra-args` setting derived
from `cpuIsolation.partitions`. Sketch:

```yaml
spec:
  workerProfiles: []   # left empty, see Option 3
  api: {}
  # the actual surface k0s exposes for kubelet flags — see Open Questions
  installConfig:
    users: {}
extensions:
  helm: {}
```

Pseudo-render (verify the actual k0s API path before implementing):

```yaml
# kubelet args, derived from cpuIsolation
--reserved-cpus=<housekeeping list>
--cpu-manager-policy=static
```

Where `<housekeeping list>` = (online cpus from `/proc/cpuinfo`) − (union
of `cpuIsolation.partitions[].cpus`).

**Pro:**
- Kubelet truly excludes isolated cores from its allocatable pool. The
  scheduler stops over-promising.
- CPUManager state file reflects reality from first boot.
- Cleanly fits the existing "phase 3 renders k0s config" pipeline.

**Con:**
- `--cpu-manager-policy` is **immutable** once kubelet has written
  `/var/lib/kubelet/cpu_manager_state`. Switching `none` → `static` on a
  running robot requires:
  1. Drain the node.
  2. Stop kubelet (`systemctl stop k0scontroller` or `k0sworker`).
  3. `rm /var/lib/kubelet/cpu_manager_state`.
  4. Update config.
  5. Restart kubelet.
- That sequence is destructive on a robot in production. It needs a
  scheduled drain window or to be folded into a re-image.
- `kubelet-extra-args` is a flat string and harder to compose with future
  kubelet flags than a structured config.

**Effort:** Small for the rendering. Migration runbook is the bulk of
the work.

### Option 3 — k0s `workerProfiles`

k0s supports per-worker config profiles at `spec.workerProfiles[]`. Each
profile carries a `KubeletConfiguration` patch. Sketch (verify exact key
names):

```yaml
spec:
  workerProfiles:
    - name: rt-isolated
      values:
        reservedSystemCPUs: "0-10"
        cpuManagerPolicy: static
```

The node opts into the profile via the
`k0sproject.io/worker-profile=rt-isolated` label (verify the exact label
key in k0s docs).

**Pro:**
- Kubelet correctness, same as Option 2.
- Declarative and structured: kubeletConfig fields, not opaque flag
  strings. Composes with future fields (memoryManagerPolicy, topology
  managers, etc.).
- Heterogeneous fleets are natural: a robot with a different partition
  layout selects a different profile.
- The label on the node makes "is this node RT-isolated?" observable
  from `kubectl get nodes`.

**Con:**
- Same `cpuManagerPolicy` immutability as Option 2; same migration cost.
- More moving parts: the profile object in the cluster config, plus
  the per-node label, plus the rendering logic.
- Profile names become a small piece of fleet vocabulary
  (`rt-isolated-12c`, `rt-isolated-16c`, …) that we have to keep coherent.
- We don't currently use `workerProfiles` for anything else, so this is
  net-new infrastructure.

**Effort:** Medium. Rendering + label management + profile naming
convention + migration runbook.

## Recommendation

**Option 3** — render a `workerProfile` and label the node into it.

Reasoning:

- We need kubelet to be correct (rules out Option 1 long-term).
- Of the two ways to make kubelet correct, the structured
  `KubeletConfiguration` surface (Option 3) is the one we'd want to grow
  into anyway. The non-goals list above (memory manager, topology
  manager) are all kubeletConfig fields. Picking the structured surface
  now means we're not re-writing this in six months.
- Per-profile labels make heterogeneous fleets tractable. A robot with
  a 16-core CPU and an EtherCAT partition on cores 13–15 gets
  `rt-isolated-16c-3rt`; a 12-core robot with 11–13 isolated gets a
  different profile. Both are rendered from the same per-host
  `cpuIsolation` block.
- Operationally, the label gives us `kubectl get nodes -L
  k0sproject.io/worker-profile` as a sanity check.

The runtime cgroup shrink (Option 1's mechanism) **stays.** Cgroup state
is the kernel-level source of truth and the safety net if kubelet config
ever drifts. Option 3 layers correctness on top of it; it does not
replace it.

### Schema choice — implicit or explicit `kubelet:` block?

Two ways to surface this in `host-config.yaml`:

- **Implicit** — derive everything from `cpuIsolation.partitions`. No new
  schema fields.
- **Explicit** — add a `kubelet:` block with `reservedCpus`,
  `cpuManagerPolicy`, etc.

**Pick implicit** for the first iteration. Justification:

1. Today there is exactly one operator-meaningful piece of input: the
   list of isolated cores. Adding a second, redundant source of truth
   invites them to drift.
2. The derivation is mechanical: housekeeping = (online cpus) −
   (union of partitions). A test fixture catches any regression in the
   derivation.
3. If a future scenario needs an escape hatch (e.g. reserve extra cores
   for systemd that aren't in any partition), we can add an optional
   `kubelet.extraReservedCpus: []` field then. Easier to add fields than
   to retire them.

## Migration plan

Two populations to migrate: new bringups, and existing in-life robots.

### Phase A — New bringups (zero-cost)

1. Land the phase 3 rendering change behind an environment flag (or a
   feature gate read from host-config — e.g. `cpuIsolation.kubeletAware:
   true`, defaulting false until phase B).
2. For any robot whose `host-config.yaml` opts in, phase 3 renders the
   `workerProfile` and the node label, kubelet starts with the correct
   `reservedSystemCPUs` and `cpuManagerPolicy=static` from first boot.
3. No `cpu_manager_state` migration: the file is written fresh, with the
   correct policy.

### Phase B — Existing robots (scheduled drains)

The state-file invalidation makes this mandatory drain work:

1. Operator schedules a drain window for the robot.
2. `kubectl cordon <node>` and drain workloads off (or rely on robot
   downtime if it's already in a maintenance state).
3. `systemctl stop k0scontroller` (or `k0sworker`).
4. `rm -f /var/lib/kubelet/cpu_manager_state`.
5. Re-run `bootstrap-robot.sh` (or just phase 3 if we expose phase
   selection) to re-render the k0s config with the new
   `workerProfile` + label.
6. `systemctl start k0scontroller`.
7. Verify: `kubectl get node <name> -o jsonpath='{.status.allocatable.cpu}'`
   matches the housekeeping count, `kubectl get node <name> -L
   k0sproject.io/worker-profile` shows the right profile, and a probe
   pod with integer CPU requests can be scheduled.
8. `kubectl uncordon <node>`.

If a robot is already going through a re-image, fold steps 3–6 into the
re-image flow.

### Phase C — Default flip

Once the fleet has been migrated, drop the feature flag. New bringups
always render the kubelet-aware config; phase 8 cgroup shrink remains
as belt-and-suspenders.

## Open questions

1. **k0s API surface.** Confirm whether the right field is
   `spec.workerProfiles[].values.reservedSystemCPUs` (KubeletConfiguration
   key) or `kubelet-extra-args: --reserved-cpus=...` under
   `installConfig` / `spec.api.extraArgs`. This RFC was drafted from the
   prompt's notes; the actual key path needs confirmation from
   <https://docs.k0sproject.io/> against the exact k0s version we ship.
   Author was unable to fetch upstream docs in this drafting session.
2. **Worker-profile label key.** Verify whether k0s uses
   `k0sproject.io/worker-profile`, `k0s.k0sproject.io/worker-profile`, or
   another spelling, and whether the label is honoured by both the
   `k0scontroller` and `k0sworker` paths.
3. **`cpuManagerPolicy=static` on the controller node.** Most of our
   robots run a single-node k0s with both `controller` and `worker`
   roles. Confirm the worker-profile applies to that combined node and
   not only to pure-worker nodes.
4. **State file path.** `/var/lib/kubelet/cpu_manager_state` is the
   upstream default; confirm k0s does not relocate it (e.g. under
   `/var/lib/k0s/kubelet/`).
5. **Housekeeping derivation edge cases.** What if `cpuIsolation` is
   empty (no partitions declared)? Render nothing — i.e. don't attach
   a worker-profile, leave kubelet at the default. What if the union of
   partitions covers all cores (operator error)? Phase 3 must reject
   the config with a clear error rather than render
   `reservedSystemCPUs=""`.
6. **Hot-reconfiguration.** If the operator changes
   `cpuIsolation.partitions` on a live robot, today's phase 8 re-applies
   the cgroup. With Option 3 we also need to re-render the
   workerProfile, which means a kubelet restart at minimum and possibly
   a `cpu_manager_state` deletion. Decide whether to support this in-life
   or require a re-image.
7. **Profile naming.** Pick a convention up front
   (`rt-isolated-<total>c-<rt>rt`?). Avoid free-form names that
   produce a long tail of one-off profiles.

## Out of scope but adjacent

- **FIR-269 — cpu-isolation phase 8.** Already shipped. This RFC
  composes with it; does not replace it.
- **Memory manager / topology manager.** Likely a follow-on (FIR-283 or
  similar). Same pattern: a `KubeletConfiguration` patch rendered from
  per-host config.
- **Fleet control plane (RFC 0001).** When the control plane is the
  source of host-config truth, it ships the `cpuIsolation` block too;
  rendering of the worker-profile becomes a control-plane concern as
  much as a device-side one. The schema choice in this RFC (implicit,
  derived from `cpuIsolation`) is forward-compatible with that move.
- **Private-repo Argo CD auth (RFC 0002).** Independent.

## Decision needed

Before implementing:

- [ ] Confirm the k0s field path (Option 3's `workerProfile.values` keys)
      against the shipped k0s version.
- [ ] Confirm the worker-profile node-label spelling.
- [ ] Sign off on the implicit-derivation schema choice (no `kubelet:`
      block in host-config for now).
- [ ] Agree on a profile-naming convention.
- [ ] Schedule drain windows for the existing robots that need the
      `cpu_manager_state` reset.
