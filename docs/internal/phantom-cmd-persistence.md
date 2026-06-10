# PHANTOM_CMD Persistence (deployments.positronic-control.launchCommand)

`PHANTOM_CMD` is the env var the `positronic-control` pod's entrypoint
exec's at startup. Empty value → the pod runs `sleep infinity` (interactive
dev mode); populated → the pod runs whatever command string is set.

Until FIR-phantom-cmd-persistence, the value lived in two places:

1. The repo's base manifest, hard-coded to `""`
   (`manifests/base/positronic/configmap.yaml`).
2. The live ConfigMap on the cluster, set with `positronic.sh set-cmd <cmd>`
   (a `kubectl patch` against the running ConfigMap).

This had a sharp edge: every time `bootstrap-robot.sh --image-overrides`
(or any operator-side `kubectl apply -k`) ran, Argo CD re-applied the
manifest's `PHANTOM_CMD: ""` and reverted the live value. New pods came up
with `sleep infinity` — no ROS 2 nodes — until someone re-ran
`positronic.sh set-cmd`. This was hit on Jun 2 when a pod rolled with a
new image and ROS 2 came up empty.

## The fix (Option A — declarative source-of-truth)

A new optional field,
`deployments.positronic-control.launchCommand`, in
`/etc/phantomos/host-config.yaml` (FIR-407 — colocated with the rest of
the positronic-control deployment-side config):

```yaml
deployments:
  positronic-control:
    launchCommand: "ros2 launch phantom_policies dma_policy_launch.py policy_path:=/root/models/walking-imu-hard-railing"
    mounts:
      - {name: recordings, host: /root/recordings, container: /recordings}
```

When set, `bootstrap-robot.sh`'s phase 15 (`--image-overrides`) and phase 16
(`--deployments`) inject a **strategic-merge patch** on
`ConfigMap/positronic-config` into the core Argo Application's
`spec.source.kustomize.patches`. The patch body looks like:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: positronic-config
  namespace: positronic
data:
  PHANTOM_CMD: "<value from host-config.yaml>"
```

Argo re-applies this on every sync, so the live ConfigMap's `PHANTOM_CMD`
key matches host-config.yaml every time the cluster is reconciled — no
more silent reversion to empty.

`data` is a strategic-merge map (merge-by-key), so `ROS_DOMAIN_ID` and any
other key in the base ConfigMap flow through untouched. We only stamp
`PHANTOM_CMD`.

## Phase wiring

| Phase | Action |
| --- | --- |
| 12 `--image-overrides` | Surgical merge into `kustomize.patches` (filters any prior `ConfigMap/positronic-config` entry, appends a fresh one if `launchCommand` is set). |
| 13 `--deployments` | Emits the same patch as part of the full `kustomize.patches` payload alongside the `deployments:` block. |

Both phases are idempotent and consistent: re-running either, or both,
produces the same live state. A full `bootstrap-robot.sh` invocation
runs phase 15 followed by phase 16, so the final list is whatever phase
13's emitter built (which already includes the PHANTOM_CMD patch).

## Backward compatibility

| Host-config state | Result |
| --- | --- |
| `deployments.positronic-control.launchCommand` absent | No patch emitted. Base manifest's `PHANTOM_CMD: ""` flows through. Pod runs `sleep infinity`. |
| `deployments.positronic-control.launchCommand: ""` (explicit) | Patch emitted with empty string. Functionally equivalent to absent, but makes the intent declarative. |
| `deployments.positronic-control.launchCommand: "<cmd>"` | Patch emitted. Pod runs `<cmd>`. |
| Legacy top-level `positronic:` block (pre-FIR-407) | `host-config.py validate` rejects it with a migration hint. |

Existing host-config.yaml files without the new field keep working
unchanged. host-configs that carried the pre-FIR-407 top-level
`positronic:` block must move the field to
`deployments.positronic-control.launchCommand`.

## Runtime override (`positronic.sh set-cmd`)

`positronic.sh set-cmd <cmd>` is **durable by default** (FIR-408): it
edits `deployments.positronic-control.launchCommand` in
`/etc/phantomos/host-config.yaml`, re-runs `bootstrap-robot.sh
--image-overrides` to propagate the change via Argo, and finally rolls
the DaemonSet. The new launch command survives every Argo sync.

Pass `--transient` to get the legacy one-off behavior — just
`kubectl patch` the live ConfigMap and roll. Useful for short-lived
test runs that shouldn't persist; the next bootstrap sync will revert
the override to whatever host-config says.

```sh
# Durable: writes host-config + propagates via Argo.
positronic.sh set-cmd ros2 launch phantom_policies dma_policy_launch.py policy_path:=/root/models/walking-imu-hard-railing

# One-off / transient: patches live ConfigMap only. Reverts on the next
# bootstrap sync.
positronic.sh set-cmd --transient sleep 60
```

## Acceptance criteria (verified on bench)

1. Adding `deployments.positronic-control.launchCommand: "<cmd>"` to
   host-config.yaml + `bootstrap-robot.sh --image-overrides` → live
   ConfigMap shows `PHANTOM_CMD: "<cmd>"`.
2. Next pod roll comes up with PHANTOM_CMD set; ROS 2 nodes start
   automatically.
3. Removing the field + re-running bootstrap → patch is scrubbed from the
   Argo app's `kustomize.patches`, `PHANTOM_CMD` reverts to `""`.
4. Existing host-config.yaml files (no `launchCommand:` under
   deployments.positronic-control) keep working unchanged.
5. `positronic.sh status` keeps printing the live PHANTOM_CMD verbatim.
6. `positronic.sh set-cmd <cmd>` (durable mode, FIR-408) edits
   host-config + re-runs bootstrap; the value survives subsequent
   bootstrap re-runs. `--transient` retains the old kubectl-patch-only
   behavior.

## Why not Argo CD `ignoreDifferences`? (Option B)

`ignoreDifferences` would let the live ConfigMap drift from the manifest
without Argo reverting it — solving the immediate symptom (set-cmd no
longer gets clobbered). But it would also leave the cluster's
`PHANTOM_CMD` in a state with no source-of-truth in git or host-config.
A new bench, a reinstall, or a fresh operator wouldn't know what value
was set; rebuilding the cluster would silently come up with `""`. Option
A keeps host-config.yaml as the single source-of-truth and matches the
pattern already used for `deployments:`, `images:`, and `cpuIsolation:`.

## Schema reference

Field: `deployments.positronic-control.launchCommand`

| Property | Value |
| --- | --- |
| Type | string |
| Required | No (optional, nested under `deployments.positronic-control`) |
| Default | absent → no patch; base manifest's `PHANTOM_CMD: ""` applies |
| Validation | `host-config.py validate` rejects non-string values, rejects `launchCommand` on any other deployment, and rejects the legacy top-level `positronic:` block with a migration hint |

The value is dropped into the ConfigMap verbatim — no shell quoting or
expansion happens on the bootstrap side. The operator is responsible for
the command string being a valid argv when split on whitespace by the
pod's entrypoint.
