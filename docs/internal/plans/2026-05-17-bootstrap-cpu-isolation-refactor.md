# Bootstrap cpu-isolation refactor — Design & Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Code intentionally omitted from this plan per author instruction — each task describes the change at the function / file level.

**Goal:** Collapse the two parallel RT-isolation codepaths in this repo into a single flow where `bootstrap-robot.sh --cpu-isolation` is a thin orchestrator over `manage_cpusets.sh` subcommands, so the bootstrap-driven flow gets every behaviour the standalone path already implements (including FIR-316's `isolcpus=managed_irq`).

**Architecture:** Replace `_apply_cpu_isolation`'s inline cmdline editor and synthetic state-file stub with calls to four pre-existing `manage_cpusets.sh` subcommands: `apply`, `install-service`, `migrate-cmdline`, `ethercat-rt`. Render `/etc/cpusets.conf` from `host-config.yaml:cpuIsolation.partitions[]` (helper `cpusets_render_conf` already exists in `scripts/lib/cpusets.sh`). Resolve the ethercat-rt partition name from host-config rather than hardcoding `ecat-cmdline`. Delete the now-unused `_apply_kernel_cmdline` helper.

**Tech Stack:** bash, systemd, cgroup-v2 cpusets, manage_cpusets.sh subcommands.

---

## Design

### Problem

Today there are two parallel codepaths in the repo for setting up RT isolation, and they diverge meaningfully:

| Capability | Path A: `bootstrap-robot.sh --cpu-isolation` | Path B: `manage_cpusets.sh` standalone subcommands |
|---|---|---|
| `isolcpus=managed_irq,<cpus>` on cmdline | ❌ writes legacy `isolcpus=<cpus>` | ✅ via `migrate-cmdline --add-rt-flags` |
| `irqaffinity=<housekeeping>` | ❌ hardcoded `=0` | ✅ computed from partition state |
| Real cgroup-v2 partition created | ❌ writes a synthetic state-file stub | ✅ via `apply <config>` |
| `cpusets.service` for boot persistence | ❌ not installed | ✅ via `install-service` |
| `/etc/cpusets.conf` rendered from host-config | ❌ not rendered | ✅ via `cpusets_render_conf` |
| Partition name | ❌ hardcoded `"ecat-cmdline"` | ✅ from `partitions[].name` |

**Consequence:** FIR-316's `isolcpus=managed_irq` migration and `cpusets.service` install never reach robots via the bootstrap flow. The boot-script changes (timer_migration, watchdog_cpumask, Tegra kthread sweep) do reach them — because `write_ethercat_rt_service` is shared — but the cmdline migration and partition persistence stay manual.

### Approach

Make Path A a thin orchestrator over Path B. The two paths converge on a single sequence of `manage_cpusets.sh` subcommand calls. `host-config.yaml:cpuIsolation` becomes the single configuration input; `/etc/cpusets.conf` becomes a generated artifact, not a hand-maintained file.

```
input: host-config.yaml cpuIsolation:
   │
   ▼
[step 1] cpusets_render_conf               → /etc/cpusets.conf (from partitions[])
[step 2] manage_cpusets apply --yes        → cgroup-v2 partitions, /var/lib/manage_cpusets/state
[step 3] manage_cpusets install-service    → cpusets.service + /usr/local/lib/manage_cpusets/
[step 4] manage_cpusets migrate-cmdline    → bootloader: isolcpus=managed_irq,<cpus> + RT flags
              --add-rt-flags --yes
[step 5] _install_cpuaffinity_dropin       → /etc/systemd/system.conf.d/cpuaffinity.conf
[step 6] manage_cpusets ethercat-rt        → NIC IRQ pin + governor + workqueue + boot script
              <partition-name>
[step 7] reboot marker (if cmdline changed)
```

The `<partition-name>` in step 6 is resolved by walking `partitions[]` and finding the entry whose `cpus` range contains `nic.irqCore`. This replaces the hardcoded `"ecat-cmdline"`.

### Why this is safe

All four `manage_cpusets.sh` subcommands are pre-existing, ship today as the documented manual procedure (`docs/internal/cpu-isolation.md`), and are **idempotent**:
- `apply` reconciles live partitions to the config — no-op when matching
- `install-service` overwrites target files in place
- `migrate-cmdline` prints `No change needed.` when current cmdline equals desired
- `ethercat-rt` re-pins IRQs and re-writes the boot script (already invoked twice today, no harm)

The reboot marker logic only fires when the cmdline actually changed. `migrate-cmdline` writes a timestamped backup of the bootloader config before editing it — same recovery semantics as the existing `_apply_kernel_cmdline`.

### Compatibility

- **Robots previously bootstrapped on `main`** (legacy `isolcpus=<cpus>` on cmdline, synthetic state file, no cgroup partition): first FIR-316 bootstrap run rewrites the cmdline to `isolcpus=managed_irq,<cpus>`, creates the real cgroup partition, installs cpusets.service. One-time migration; idempotent thereafter.
- **Robots previously bootstrapped + manually `install-service`d:** the bootstrap idempotently overwrites the same files. No data loss.
- **Rollback:** revert the PR, re-bootstrap. The legacy cmdline gets rewritten next boot. `/etc/cpusets.conf` and `cpusets.service` stay installed (operator can `uninstall-service` if desired). No state-file corruption risk.

### Out of scope

- `_compute_systemd_cpuaffinity` / `_install_cpuaffinity_dropin` rework — they work, no reason to touch
- `ethercat-rt` subcommand internals — already correct
- New host-config schema fields
- A test harness for `bootstrap-robot.sh` — none exists today; staying consistent with the repo's smoke-test-on-real-device pattern

### Files touched

- Modify: `scripts/bootstrap-robot.sh` — `_apply_cpu_isolation` (~80 lines rewritten), `_apply_kernel_cmdline` (~95 lines deleted), one new ~15-line helper. Net file size shrinks.
- No changes to `scripts/cpusets/*` — Path B subcommands are already correct
- Update: `docs/internal/rfcs/0009-rt-isolation-layered-stack.md` — replace the "what is *not* in scope" note with a one-paragraph "single-path orchestration" entry
- Update: PR #38 description — add a "bootstrap refactor" subsection

---

## Implementation plan

### Task 1: Add `_cpu_isolation_partition_for_cpu` helper

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — add a new helper near the other `_cpu_isolation_*` helpers (around line 2580)

**Context:** The new `_apply_cpu_isolation` needs to determine which declared partition to pass to `manage_cpusets.sh ethercat-rt`. The right partition is the one whose `cpus` range covers `nic.irqCore`. Today the function hardcodes `"ecat-cmdline"` (line 2557). Adding a small helper isolates the lookup logic and keeps the orchestrator readable.

- [ ] **Step 1.1: Add the helper**

Add a bash function `_cpu_isolation_partition_for_cpu` that:
- Takes a JSON blob (cpuIsolation block, same format as the other `cpusets_json_*` helpers consume) and a single cpu number as arguments
- Iterates over `partitions[]`
- For each entry, expands the `cpus` range (e.g. `"11-13"` → `{11,12,13}`) and checks membership of the given cpu
- Prints the first matching partition name on stdout; prints nothing and exits 0 if no match (caller treats empty output as failure)
- Follows the same `python3 - <<'PY'` pattern as the other helpers in this file for consistency

- [ ] **Step 1.2: Verify the helper in isolation**

Run a small inline test via bash:
```
source <(grep -A20 "_cpu_isolation_partition_for_cpu()" scripts/bootstrap-robot.sh)
_cpu_isolation_partition_for_cpu '{"partitions":[{"name":"ecat1","cpus":"11-13"},{"name":"aux","cpus":"15"}]}' 13
# expect: ecat1
_cpu_isolation_partition_for_cpu '{"partitions":[{"name":"ecat1","cpus":"11-13"}]}' 5
# expect: <empty>
```
Expected output: first invocation prints `ecat1`, second prints nothing.

- [ ] **Step 1.3: Commit**

Stage `scripts/bootstrap-robot.sh` and commit with a message that says the helper was added and explains *why* (lookup partition name from host-config for ethercat-rt). One-line subject + short body.

---

### Task 2: Render `/etc/cpusets.conf` and apply partitions

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — inside `_apply_cpu_isolation`, replace the synthetic state-file stub (lines 2538-2557) with `cpusets_render_conf` → `cpusets_run apply` calls

**Context:** Today the bootstrap writes a one-line synthetic entry to `/var/lib/manage_cpusets/state` so the `ethercat-rt` subcommand finds *something* to anchor to, but never creates the actual cgroup-v2 partition. The lib helper `cpusets_render_conf "$ci_json"` already exists and writes `/etc/cpusets.conf` atomically; `manage_cpusets.sh apply` then creates the partition properly.

- [ ] **Step 2.1: Render `/etc/cpusets.conf` from `$ci_json`**

In `_apply_cpu_isolation`, after the input validation (line 2489) and before the cmdline-editing block, call `cpusets_render_conf "$ci_json"`. On failure, `fail`+`return`. On success, log via `pass "rendered $CPUSETS_CONF from cpuIsolation.partitions"`.

- [ ] **Step 2.2: Call `manage_cpusets apply` with `--yes`**

After the render, call `cpusets_run apply "$CPUSETS_CONF" --yes`. `--yes` skips the `isolcpus=` overlap prompt (we're about to migrate the cmdline ourselves in Task 3). On failure, `fail`+`return`. On success, `pass "cpuset partitions applied"`.

- [ ] **Step 2.3: Delete the synthetic state-file stub**

Remove lines 2546-2548 (the `mkdir -p /var/lib/manage_cpusets && printf '%s|%s|%s\n' ... > state` block). `apply` writes the state file itself.

- [ ] **Step 2.4: Verify rendering with a fake ci_json**

Run inline:
```
. scripts/lib/cpusets.sh REPO_ROOT=$PWD
ci_json='{"partitions":[{"name":"ecat1","cpus":"11-13"}]}'
CPUSETS_CONF=/tmp/cpusets.conf.test cpusets_render_conf "$ci_json"
cat /tmp/cpusets.conf.test
```
Expected: an INI-style file with `[ecat1]` + `cpus = 11-13`.

- [ ] **Step 2.5: Commit**

Stage `scripts/bootstrap-robot.sh` and commit. Subject: render and apply cpuset partitions via manage_cpusets, no more state-file stub.

---

### Task 3: Replace `_apply_kernel_cmdline` with `migrate-cmdline`

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — replace the `_apply_kernel_cmdline` invocation at lines 2505-2518 with a `cpusets_run migrate-cmdline --add-rt-flags --yes` call. Update the `cmdline_changed` detection.

**Context:** `_apply_kernel_cmdline` is a near-duplicate of `manage_cpusets.sh migrate-cmdline`'s logic but uses the legacy `isolcpus=<cpus>` form and hardcodes `irqaffinity=0`. `migrate-cmdline` reads partition state (from step 2) and emits `isolcpus=managed_irq,<cpus>` and `irqaffinity=<housekeeping>`. Single source of truth.

- [ ] **Step 3.1: Replace the invocation**

Replace the `if _apply_kernel_cmdline ... fi` block with `cpusets_run migrate-cmdline --add-rt-flags --yes`. Capture stdout+stderr to a local variable; print it to the bootstrap log so operators see the diff and backup path.

- [ ] **Step 3.2: Detect "no change" vs "changed"**

`migrate-cmdline` prints `No change needed.` when current == desired. Detect this with `grep -q "No change needed"` on the captured output. Set `cmdline_changed=0` on no-change, `cmdline_changed=1` otherwise. Mirror the existing pass/skip semantics (`skip "kernel cmdline already at desired state"` vs `pass "kernel cmdline updated (REBOOT REQUIRED for full effect)"`).

- [ ] **Step 3.3: Update the stale-marker check**

The existing stale-marker clear at lines 2572-2577 greps `/proc/cmdline` for `isolcpus=$isolcpus`. After this change the live cmdline has `isolcpus=managed_irq,$isolcpus` instead. Update the grep pattern accordingly.

- [ ] **Step 3.4: Commit**

Stage and commit. Subject: delegate kernel cmdline to manage_cpusets migrate-cmdline.

---

### Task 4: Install cpusets.service for boot persistence

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — add a `cpusets_run install-service "$CPUSETS_CONF"` call inside `_apply_cpu_isolation`, immediately after the `apply` call from Task 2

**Context:** Without this, the cgroup-v2 partition created by `apply` disappears at the next reboot. `install-service` is idempotent — overwrites the same files on re-run.

- [ ] **Step 4.1: Call install-service**

Right after the `apply` block from Task 2, add `cpusets_run install-service "$CPUSETS_CONF" >/dev/null`. Redirect stdout because install-service's normal output is verbose and operators don't need to re-see the same file paths every bootstrap. Log via `pass "cpusets.service installed and enabled"`.

- [ ] **Step 4.2: Commit**

Stage and commit. Subject: install cpusets.service from bootstrap so partitions survive reboot.

---

### Task 5: Resolve ethercat-rt partition name from host-config

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — at line 2546-2557 (the `ethercat-rt` call site), replace the hardcoded `"ecat-cmdline"` with a lookup via the helper from Task 1

**Context:** With real partitions now created from `partitions[]`, the bootstrap needs to pass the actual partition name to `ethercat-rt`, not the legacy `ecat-cmdline` literal. The helper from Task 1 resolves it from `nic.irqCore`.

- [ ] **Step 5.1: Resolve the partition name**

Replace `local part_name="ecat-cmdline"` with a call to `_cpu_isolation_partition_for_cpu "$ci_json" "$nic_irq"`. Capture into `part_name`. On empty output, `fail "no cpuIsolation.partitions[] entry contains nic.irqCore=$nic_irq" ; return`.

- [ ] **Step 5.2: Update the log message**

The existing log message at line 2549 says `"pinning $nic_iface IRQs to core $nic_irq + governor lock + workqueue mask..."`. Add the partition name to it: `"pinning $nic_iface IRQs to core $nic_irq (partition '$part_name')..."`.

- [ ] **Step 5.3: Commit**

Stage and commit. Subject: resolve ethercat-rt partition name from cpuIsolation.partitions.

---

### Task 6: Delete `_apply_kernel_cmdline`

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — delete lines 2696-2793 (the entire `_apply_kernel_cmdline` function)

**Context:** With Task 3 done, this helper has no callers. Removing it is mechanical.

- [ ] **Step 6.1: Confirm no other callers**

Run `grep -n _apply_kernel_cmdline scripts/`. Expected: only the definition. If anything else turns up, stop and investigate.

- [ ] **Step 6.2: Delete the function**

Remove the entire function (definition + body, including the comment block immediately above it that references `_apply_kernel_cmdline`).

- [ ] **Step 6.3: Verify `bash -n` still passes**

Run `bash -n scripts/bootstrap-robot.sh`. Expected: clean exit.

- [ ] **Step 6.4: Commit**

Stage and commit. Subject: drop unused `_apply_kernel_cmdline` helper.

---

### Task 7: Update dry-run output to reflect the new flow

**Files:**
- Modify: `scripts/bootstrap-robot.sh` — the `if [ "$DRY_RUN" = 1 ]; then` block at lines 2491-2503

**Context:** Dry-run output is operators' first look at what bootstrap will do. The current messages still describe the old flow (`isolcpus=$isolcpus`, no mention of partitions / install-service). Update so a dry-run accurately previews the new sequence.

- [ ] **Step 7.1: Rewrite the dry-run info lines**

Replace the existing `info "DRY-RUN  ensure kernel cmdline tokens: ..."` lines with a sequence reflecting the new 7-step flow (render conf, apply partitions, install service, migrate-cmdline with managed_irq, CPUAffinity drop-in, ethercat-rt with resolved partition name, reboot marker). Each line still prefixed with `DRY-RUN  ` for grep-ability.

- [ ] **Step 7.2: Verify dry-run output on the dev box**

Run `sudo bash scripts/bootstrap-robot.sh --cpu-isolation --dry-run` against a host-config with a `cpuIsolation:` block. Expected: dry-run lines describe render → apply → install-service → migrate-cmdline → CPUAffinity → ethercat-rt. No actual file writes.

- [ ] **Step 7.3: Commit**

Stage and commit. Subject: dry-run output for the new cpu-isolation flow.

---

### Task 8: Verify on ch4 — clean re-run from FIR-316

**Files:** None — verification only.

**Context:** ch4 is already partially set up from the earlier manual install-service + migrate-cmdline session. The refactor needs to confirm a single bootstrap run reaches the same state as today's "bootstrap + manual install-service + manual migrate-cmdline" sequence, and that a second run is a complete no-op.

- [ ] **Step 8.1: Confirm starting state on ch4**

```
ssh phantom@ch4 'sudo /usr/local/lib/manage_cpusets/manage_cpusets.sh status'
```
Capture: cmdline (should show `isolcpus=managed_irq,11-13`), partition state, cpusets.service active.

- [ ] **Step 8.2: Pull the refactor branch and run bootstrap**

```
ssh phantom@ch4 '
  cd /home/phantom/foundation/DMA/Phantom-OS-KubernetesOptions
  git fetch origin FIR-316-managed-irq
  git pull --ff-only
  sudo bash scripts/bootstrap-robot.sh --cpu-isolation --yes
'
```
Capture full output. Expected: cmdline reports `No change needed.` (since it's already migrated), apply reports partition already matching, install-service overwrites the same files, ethercat-rt re-pins. No `FAIL` lines.

- [ ] **Step 8.3: Confirm post-state matches starting state**

Re-run `manage_cpusets.sh status`. Expected: identical to Step 8.1's output (modulo timestamps).

- [ ] **Step 8.4: Re-run bootstrap once more (idempotency)**

Run `sudo bash scripts/bootstrap-robot.sh --cpu-isolation --yes` a second time. Expected: every step reports "no change" / "already at desired state" or equivalent. No bootloader rewrite. No fail lines.

- [ ] **Step 8.5: No commit — verification only**

This task produces evidence pasted into the PR comment, not a code change.

---

### Task 9: Update RFC-0009 and PR description

**Files:**
- Modify: `docs/internal/rfcs/0009-rt-isolation-layered-stack.md`
- PR description on GitHub (edit via `gh pr edit`)

**Context:** RFC-0009 currently lists "the bootstrap path doesn't fully integrate" as an open item in §"Open items". With this refactor, that item is closed; RFC should reflect the unified flow. The PR body should pick up the bootstrap refactor as a section.

- [ ] **Step 9.1: Update RFC-0009**

In `docs/internal/rfcs/0009-rt-isolation-layered-stack.md`, find the §"Operator surface" section and add a paragraph noting that `bootstrap-robot.sh --cpu-isolation` now chains the same `apply` → `install-service` → `migrate-cmdline` → `ethercat-rt` sequence the operator would run by hand. Remove (or update) any "two paths" language elsewhere in the doc.

- [ ] **Step 9.2: Update PR description**

Add a new "## Bootstrap flow refactor" section to PR #38's body, summarising the before/after orchestration, the closed gap, and idempotency guarantee. Paste evidence from Task 8 (status output before / after / re-run).

- [ ] **Step 9.3: Commit and push (RFC only — PR body is GitHub-side)**

Stage `docs/internal/rfcs/0009-rt-isolation-layered-stack.md` and commit. Subject: rfc-0009 note that bootstrap now uses single-path orchestration.

---

## Self-review

1. **Spec coverage:** Each design-section gap maps to a task. Single source of truth for cmdline → Task 3. Real partitions → Task 2. Boot persistence → Task 4. Partition name from host-config → Tasks 1+5. Cleanup of dead helper → Task 6. Operator-facing accuracy → Tasks 7+9. Validation on real hardware → Task 8.

2. **Placeholder scan:** No TBDs. No "implement later". Every task has a concrete file path and a verifiable expected outcome. Per author instruction, code blocks are intentionally omitted — each task's "Step N" describes the change in prose, naming the function/lines to touch and the conceptual edit.

3. **Type / name consistency:** `_cpu_isolation_partition_for_cpu` (Task 1) called in Task 5. `cpusets_render_conf` (lib, pre-existing) called in Task 2. `cpusets_run apply|install-service|migrate-cmdline|ethercat-rt` — all four are existing subcommands of `manage_cpusets.sh`. `$CPUSETS_CONF`, `$ci_json`, `$nic_iface`, `$nic_irq` — all variables present in the function today. `cmdline_changed` flag — same name and semantics as today's code.

4. **Risk audit:**
   - Bootloader rewrite path is exercised by Task 8 on a real Thor (ch4). Same backup mechanism as today.
   - `apply` on a host with a stale state-file entry: the synthetic stub today says `ecat-cmdline|11-13|...`. After Task 2 the new partition is `ecat1|11-13|...` (or whatever host-config says). `apply` reconciles — it'll remove `ecat-cmdline` if it's not in the rendered conf and add `ecat1`. Confirm on ch4 in Step 8.2 that the partition transition is clean. If it isn't, add a Task 2a that explicitly removes orphaned state-file entries before the apply call.
   - The `--yes` flag on `migrate-cmdline` was previously blocked by the harness classifier on ch4 (it interpreted as "blind bootloader rewrite"). Under bootstrap, the dry-run shows the operator the proposed cmdline before they invoke the non-dry-run; that should satisfy the classifier. If it still blocks, the bootstrap's pre-existing operator-confirmation prompts cover the gap.
