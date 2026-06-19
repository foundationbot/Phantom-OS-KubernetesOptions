# Phantom-OS-KubernetesOptions

GitOps deployment for the Phantom robot fleet on k0s + ArgoCD. Per-host config
lives in `/etc/phantomos/host-config.yaml` (single source of truth); bootstrap
renders the per-stack Argo Applications, node labels, and host-local ConfigMaps
from it. Workloads are organized into **stacks** (`core` = always-on robot
workloads; `operator` = UI/episode storage) under `manifests/stacks/`.

Key files:
- `manifests/base/<workload>/` — one dir per workload (DaemonSet/Deployment + kustomization).
- `manifests/stacks/{core,operator}/kustomization.yaml` — which workloads each stack includes.
- `scripts/lib/host-config.py` — host-config schema, validation, and emitters. The registries (`NODE_LABEL_REGISTRY`, `CONTAINER_TARGETS`, `DEPLOYMENT_TARGETS`) are the source of truth for what a host-config may declare. Has pytest coverage in `scripts/lib/test_*.py`.
- `scripts/bootstrap-robot.sh` — phased bringup; per-host ConfigMaps are rendered by `*-config` phases.
- `scripts/positronic.sh` — operator convenience CLI (status/logs/exec per workload).
- `host-config-templates/_template/host-config.yaml` — the documented schema operators copy.

---

## PATTERN: Adding a new workload to the fleet k0s stack

**When to use:** any request to "deploy `<thing>` to the robots / k0s / the fleet,"
"add `<thing>` to the core stack," or "run `<thing>` on the robot like
positronic/locomotion." Do NOT hand-write a one-off manifest — follow this
established paradigm so the workload gets node-label gating, per-host image
overrides, per-host config, validation, and operator tooling for free.

**Canonical precedents (read the most recent one first, then mirror it 1:1):**
`phantom-sonic` (multi-container "brain" pod), `phantom-locomotion`,
`positronic-control`, `cpp-robot-state-estimator`, `okvis2x`. A fully worked
example with design + phased plan: `wm-inference`
(`docs/superpowers/specs/2026-06-18-wm-inference-deployment-design.html` +
`docs/superpowers/plans/2026-06-18-wm-inference-deployment.md`).

**The touchpoints (each new workload edits roughly these files):**

1. **Manifest** — `manifests/base/<workload>/{<workload>.yaml,kustomization.yaml}`.
   - DaemonSet (not Deployment) for per-node robot workloads, so opting out via
     nodeSelector yields zero pods rather than a Pending replica.
   - `nodeSelector: { foundation.bot/robot: "true", foundation.bot/has-<x>: "true" }`,
     blanket `NoSchedule` toleration, `runtimeClassName: nvidia` for GPU,
     `imagePullSecrets: [dockerhub-creds]`, namespace usually `positronic`.
   - Use **local-registry image placeholders** (`localhost:5443/<name>:PLACEHOLDER`),
     never digest pins — the per-host `images:` override rewrites them.
   - Bundle weights via an init-container that copies an immutable data-image
     into a shared `emptyDir` (k0s containerd has only partial image-volume support).
2. **Stack include** — add `../../base/<workload>` to `manifests/stacks/core/kustomization.yaml`.
3. **Node label** — add `foundation.bot/has-<x>` (default `"false"`) to `NODE_LABEL_REGISTRY`.
4. **Image override targets** — add the main image (and any data/init image, e.g. `<name>-models`) to `CONTAINER_TARGETS`.
5. **Per-host config** (if the workload has tunables) — a `<workload>:` host-config
   block + a `DEFAULT_*`/`FIELD_TO_ENV` emitter (`cmd_get_<workload>-config-kv`,
   wired into `main()`'s dispatch) + a validation block. Delivered via a
   bootstrap `*-config` phase that renders a host-local ConfigMap the pod reads
   via `envFrom: { optional: true }`. Carry matching shell-defaults in the
   manifest command so the pod boots before the CM exists.
6. **Bootstrap phase** — add `--<workload>-config` flag, `SKIP_<X>_CONFIG`,
   `SELECTED_PHASES` case entries, the `<workload>_config()` function, and the
   call in the run list. Mirror `sonic_config()`.
7. **Operator CLI** — add a subcommand group to `scripts/positronic.sh` (mirror the `sonic`/`wm` groups).
8. **Mount/arg overrides** (only if needed) — add to `DEPLOYMENT_TARGETS`.
9. **Docs** — document the node label, image keys, and config block in
   `host-config-templates/_template/host-config.yaml`; add a runbook section to `docs/operations.md`.
10. **Tests** — add `scripts/lib/test_host_config_<workload>.py` (mirror `test_host_config_okvis2x.py`); cover label/images/emitter/validation. TDD the `host-config.py` changes.

### Variant: mutually-exclusive "control brain"

A workload that drives `/desired` (or whose co-located container does) is a
"control brain" — `positronic-control`, `phantom-locomotion`, `phantom-sonic`,
and `wm-inference` are mutually exclusive: **at most one `has-*` brain label may
be `"true"` per robot.** `has-positronic` is default-on, so enabling any other
brain requires explicitly setting `has-positronic: "false"`. This is enforced by
the `enabled_drivers` list in `host-config.py:validate()` — add the new label to
that tuple and to the error-message string. The Pod (not the individual
container) is the exclusion unit, so a brain pod with a not-yet-shipped
co-located container still claims the slot.

### Config-delivery mechanism: pick by how the image starts

- **Shell-entrypoint workloads** (image runs a script like `dma_launch.sh`):
  use the **sonic/locomotion mechanism** — host-local ConfigMap applied directly
  by the bootstrap phase (ArgoCD-unmanaged, `--reset`-preserved), `envFrom optional`,
  and `${VAR:-default}` shell-defaults in the command. No base CM in git (avoids
  ArgoCD drift conflict). Simplest; preferred default.
- **Image-entrypoint workloads** (a bare binary): either wrap it in a thin
  `/bin/sh -c 'export VAR=${VAR:-default}; exec <binary>'` shell to reuse the
  sonic mechanism (preferred — see `wm-inference`), OR use the **positronic
  mechanism** (base CM in git + a strategic-merge patch injected into the core
  Argo Application's `spec.source.kustomize.patches`, drift-safe) when you need
  ArgoCD to re-apply per-host values on every sync.

### Validation before claiming done

- `python3 -m pytest scripts/lib/ -v` (no regressions in sibling workload tests).
- `kubectl kustomize manifests/stacks/core | kubectl apply --dry-run=client -f -`.
- `python3 scripts/lib/host-config.py <sample-host-config.yaml> validate` for an
  enabled robot (and a negative case proving the exclusion fires).
- `bash -n` on any edited shell script.

---

## Conventions

- Commit messages: **omit the `Co-Authored-By: Claude` trailer.**
- Feature work goes on a branch; the docs/spec/plan for a workload live under
  `docs/superpowers/{specs,plans}/`.
