# RFC 0008 — Phase 10 should delete Argo Apps for disabled stacks

**Status:** sketch
**Companion:** RFC 0005 (image overrides) — surfaced this gap during smoke testing on mk09.

## Problem

`bootstrap-robot.sh` phase 10 (`gitops`) reads host-config's
`stacks:` block and renders one `Application` CR per **enabled**
stack into `/etc/phantomos/phantomos-app-<stack>.yaml`, then
`kubectl apply`s each. Phase 12 (`image_overrides`) similarly
patches only the enabled stacks' Applications.

If a stack transitions from enabled → disabled (operator runs the
wizard, sets `stacks.<x>.enabled: false` and re-runs bootstrap),
phase 10 stops rendering and applying its Application. **But the
existing Application from the previous run stays in Argo.** It's
orphaned: still tracking its repo path, still serving its
manifests, still carrying whatever `kustomize.images` overrides
phase 12 last wrote.

The orphan's symptoms — observed on mk09:
- Argo `Application/phantomos-mk09-operator` shows `OutOfSync` /
  `Healthy` indefinitely (no auto-sync to apply current overrides
  and no deletion).
- Stale `kustomize.images: [foundationbot/argus.operator-ui:REPLACE-WITH-OPERATOR-UI-COMMIT-SHA]`
  hangs around from a prior wizard run with placeholder defaults.
- If a manual sync is triggered (operator clicks "Sync" in the
  Argo UI, or `argocd app sync` from the command line), Argo
  re-renders the manifests with the bad override and rolls a
  broken operator-ui pod into the cluster.

This is a footgun. The wizard says "operator stack disabled" and
the operator reasonably expects that to mean "operator stack is
gone." Today it means "operator stack is on the way out, but
state-from-when-it-was-enabled is alive and dangerous."

## Proposal

Phase 10 (`gitops`) gains a cleanup pass that runs alongside the
existing render-and-apply loop:

```bash
# Existing: for each enabled stack, render and apply.
for stack in $enabled_stacks; do
  render_app "$stack"
  apply_app "$stack"
done

# NEW: for each non-enabled stack in KNOWN_STACKS, delete its
# Application if it exists. Argo's resources-finalizer cascades
# to delete the rendered child resources (operator-ui Deployment,
# nimbus.eg-server, etc.).
for stack in $KNOWN_STACKS; do
  if echo "$enabled_stacks" | grep -qF -x "$stack"; then
    continue
  fi
  app="phantomos-${ROBOT}-${stack}"
  if kubectl -n argocd get application "$app" >/dev/null 2>&1; then
    info "stack $stack disabled — deleting orphan $app"
    kubectl -n argocd delete application "$app" --wait=false
    pass "deleted orphan $app"
  fi
done
```

Notes:
- Use `KNOWN_STACKS` from `host-config.py` (currently `("core",
  "operator")`). Don't hard-code in bash — fetch via
  `host-config.py get-known-stacks` (new sub-command, ~5 lines).
- Argo's `finalizers: [resources-finalizer.argocd.argoproj.io]`
  on the rendered Application CR makes deletion cascade to all
  the children. The pod cleanup happens server-side; bootstrap
  doesn't have to babysit it. `--wait=false` lets phase 10 move
  on without blocking on cascade completion.
- Required stacks (currently just `core`) can never be disabled
  — `host-config.py` validate already enforces this. So phase 10
  can safely delete any non-required stack's Application.

### Operator-facing behavior

When `stacks.<x>.enabled: false`:
- New `Application` is not created (existing behavior).
- Existing `Application` is deleted (new behavior).
- Argo's cascade handles the workload teardown.
- Phase 12 then no-ops for that stack (already correct).

When `stacks.<x>.enabled: true` (or the field is absent):
- `Application` is rendered + applied (existing behavior).
- Phase 12 patches its `kustomize.images` (existing behavior).

### Idempotence

- Running phase 10 twice when a stack is already disabled: the
  first deletion succeeds; the second's `kubectl get application`
  returns NotFound and the cleanup loop skips it. Idempotent.
- Re-enabling a previously-disabled stack: existing render-and-
  apply path creates the Application from scratch, no orphan
  state to merge with.

## Trade-offs

### Pro: removes a real footgun

The orphan state can roll broken pods into a cluster the next
time someone clicks "Sync." Cleaning it up at bootstrap-time is
the operator-friendly behavior.

### Pro: matches operator mental model

"Disabled stack" should mean "stack is gone." Today it means
"new versions of stack manifests aren't applied, but old state
persists." That's surprising.

### Con: data loss risk

Deleting the Application cascades to its children — including
PersistentVolumes/PVCs the workload may have populated. For
stacks like `operator` (mongodb, eg-server with their own data)
this could mean **operator data loss**.

Mitigation:
- The `Argo` `Application` CR's `syncPolicy` controls cascade
  behavior. If we set `--cascade=orphan` on the delete, child
  resources stay alive (just no longer Argo-managed). Operators
  can clean up manually.
- Or: deletion goes to a different code path that explicitly
  preserves PV/PVC resources. Per-stack policy.

Lean: **`--cascade=orphan` by default**. Phase 10 prints a clear
log line ("orphaned app phantomos-mk09-operator; PV/PVC
resources retained — `kubectl delete -n argus all --selector
app.kubernetes.io/part-of=phantomos`  to clean up workloads
manually") so operators know how to follow up. This is the
non-destructive default.

`--cascade=orphan` operators an opt-in `--purge-disabled-stacks`
flag (or a host-config field `stacks.<x>.purgeOnDisable: true`)
for operators who really want a clean wipe.

### Con: operators who set `enabled: false` to suppress wizard prompts

A possible (mis)use of `enabled: false` is "I don't want to
configure this stack right now, leave the existing pods alone."
Today that works because the wizard skips it but Argo keeps
managing it. After this RFC, that workflow breaks — disabled
means deleted.

Mitigation: document the change clearly in the wizard's
help text + a one-time bootstrap warning when `enabled: false`
flips to actually-deleting behavior on first run after the RFC
ships.

## Implementation footprint

- `scripts/lib/host-config.py`: +5 lines for `get-known-stacks`
  command.
- `scripts/bootstrap-robot.sh:gitops()`: +20 lines for the
  cleanup loop (orphan detection + delete).
- Optional: +5 lines for `--purge-disabled-stacks` flag handling.
- Docs: brief paragraph in `docs/architecture.md` explaining
  enabled/disabled semantics.

## Validation plan

1. Start with both stacks enabled, run bootstrap, confirm both
   Applications exist.
2. Set `stacks.operator.enabled: false`, re-run `bootstrap-robot.sh
   --gitops`, confirm `phantomos-mk09-operator` is deleted (with
   `--cascade=orphan` semantics: workloads stay running).
3. Re-run bootstrap once more — should be a no-op (Application
   already absent).
4. Set `stacks.operator.enabled: true`, re-run bootstrap, confirm
   Application is created again from scratch (no orphan state to
   merge).
5. Test the `--purge-disabled-stacks` opt-in (or per-stack
   `purgeOnDisable: true`) — workloads ARE deleted.

## Out of scope

- Generalizing to "delete any Application not rendered by phase
  10" (i.e. operator-applied custom Apps). Scope is strictly
  phantomos-<robot>-<stack> for stacks the wizard manages.
- Argo's own admin namespace cleanup (argocd, kube-system).
- Deciding cluster-wide policies for retention of PVCs across
  re-installs. That's a backup/DR conversation, separate.
