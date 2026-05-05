# Phantom-OS Edge Cluster Architecture

> Configuration and render architecture of the per-robot Kubernetes bringup flow.
> Audience: a senior engineer encountering this repo for the first time.
> Companion docs: [operations.md](./operations.md) (operator runbook + troubleshooting),
> [RFC 0001 — Fleet control plane](./rfcs/0001-fleet-control-plane.md) (long-term direction).

## Table of contents

1. [Why this design](#1-why-this-design)
2. [Three layers (repo / host / cluster)](#2-three-layers-repo--host--cluster)
3. [Files in the repo](#3-files-in-the-repo)
4. [Files on the host (/etc/phantomos/*)](#4-files-on-the-host-etcphantomos)
5. [host-config.yaml schema](#5-host-configyaml-schema)
6. [Bootstrap phases](#6-bootstrap-phases)
7. [Per-stack Application model](#7-per-stack-application-model)
8. [Render flow](#8-render-flow)
9. [Per-host injection mechanics](#9-per-host-injection-mechanics)
10. [Idempotency and self-skip](#10-idempotency-and-self-skip)
11. [Migration history](#11-migration-history)
12. [How to extend](#12-how-to-extend)
13. [References](#13-references)

---

## 1. Why this design

This repository is a **library**. It contains every manifest, script, kustomize
overlay, and Terraform module needed to bring a fresh machine to a working
single-node k0s cluster running the Phantom-OS workloads. It does **not**
contain per-robot data. There is no `manifests/robots/<name>/` directory, no
robot-specific branch, no Application CR file checked in for any specific
device. Every robot in the fleet pulls the same repo at the same commit and
ends up running a different workload set, parameterized entirely by what is on
the local disk at `/etc/phantomos/`.

Per-host configuration lives **on the device**, in a single file:
`/etc/phantomos/host-config.yaml`. It is the source-of-truth for robot
identity, AI PC pairing, image tag overrides, and per-deployment hostPath
mounts. Bootstrap (`scripts/bootstrap-robot.sh`) reads it once at bringup,
derives every other piece of host-local state from it (rendered Application
CRs, ConfigMaps, the persisted robot-id), and injects per-host fields into
the live ArgoCD Applications via `spec.source.kustomize.{images,patches}`.
Re-running bootstrap with the same file is idempotent; changing a tag in the
file and re-running propagates the change to ArgoCD without a git commit.

The long-term destination is a **fleet control plane**: at bringup, devices
will identify themselves by hardware serial and query a control-plane API
that returns the rendered host-config and Application CRs. Operators will
manage robots through that API, not through PRs to this repo. The current
on-device file is a stepping stone: same surface, different backing store.
See [RFC 0001](./rfcs/0001-fleet-control-plane.md) for the migration plan.

## 2. Three layers (repo / host / cluster)

The system is best understood as three distinct layers, each with its own
lifecycle and responsibility. Confusing them is the most common source of
bugs in this codebase.

**Repo layer.** Everything checked into git. Manifests under
`manifests/base/<workload>/` (the universal definition of each workload),
kustomize roots under `manifests/stacks/<name>/` (the bundling units that
ArgoCD points at), the Application CR template
`host-config-templates/_template/phantomos-app.yaml.tpl`, the host-config
schema template `host-config-templates/_template/host-config.yaml`, the
bootstrap orchestrator `scripts/bootstrap-robot.sh`, the interactive wizard
`scripts/configure-host.sh`, and the parser library
`scripts/lib/host-config.py`. Identical on every device.

**Host layer.** Everything under `/etc/phantomos/` on the device.
`host-config.yaml` is the source-of-truth; `robot` (a one-line file with the
robot identity), `operator-ui-pairing.yaml` (the AI-PC URL extracted from
host-config), and `phantomos-app-<stack>.yaml` (the per-stack Application CRs
rendered from the template) are derived from it. None of these files are in
git. Their lifetime is bounded by the lifetime of the device; reflashing
wipes them.

**Cluster layer.** Kubernetes objects on the running k0s cluster. ArgoCD is
installed via Terraform's argocd Helm chart. The per-robot `phantomos-<robot>-core`
and `phantomos-<robot>-operator` Application CRs (kubectl-applied from the
rendered files in the host layer) tell ArgoCD to reconcile
`manifests/stacks/core/` and `manifests/stacks/operator/` from this repo.
Bootstrap then patches each Application's `spec.source.kustomize.{images,patches}`
with the host-specific overrides. ArgoCD takes it from there.

```
+-------------------------------------------------------------------+
|                          REPO LAYER (git)                          |
|                                                                    |
|  manifests/base/<workload>/         Universal Deployments,         |
|  manifests/stacks/<name>/             Services, ConfigMaps;        |
|  host-config-templates/_template/     stack kustomizations bundle  |
|  scripts/bootstrap-robot.sh           them into deployable units.  |
|  scripts/configure-host.sh            Identical on every device.   |
|  scripts/lib/host-config.py                                        |
|  terraform/                                                        |
+-------------------------------------------------------------------+
                                |
                                |  scripts/configure-host.sh writes,
                                |  bootstrap-robot.sh reads
                                v
+-------------------------------------------------------------------+
|                       HOST LAYER (/etc/phantomos/)                 |
|                                                                    |
|  host-config.yaml          source-of-truth (operator-edited)       |
|  robot                     persisted robot-id (one line)           |
|  operator-ui-pairing.yaml  derived: AI_PC_URL                      |
|  phantomos-app-core.yaml   derived: rendered Application CR        |
|  phantomos-app-operator.yaml derived: rendered Application CR      |
+-------------------------------------------------------------------+
                                |
                                |  kubectl apply (per stack);
                                |  kubectl patch kustomize.{images,patches}
                                v
+-------------------------------------------------------------------+
|                  CLUSTER LAYER (running k0s + ArgoCD)              |
|                                                                    |
|  Application phantomos-<robot>-core      -> manifests/stacks/core/ |
|  Application phantomos-<robot>-operator  -> manifests/stacks/op/   |
|       \                                                            |
|        +--> ArgoCD reconciles workload trees with per-host         |
|             kustomize.images and kustomize.patches injected        |
+-------------------------------------------------------------------+
```

## 3. Files in the repo

| Path | Purpose |
| --- | --- |
| `scripts/bootstrap-robot.sh` | Orchestrator. Drives every phase from preflight through validate. Idempotent; phases can be selected via `--<phase>` flags. |
| `scripts/configure-host.sh` | Interactive wizard that produces `/etc/phantomos/host-config.yaml`. Pre-fills from existing host-config when re-run. |
| `scripts/lib/host-config.py` | Parser/validator. Exposes `get`, `get-images-json`, `get-deployment-patches-json`, `get-enabled-stacks`, `get-stack-selfheal`, `validate` subcommands. Holds `KNOWN_STACKS`, `REQUIRED_STACKS`, `DEPLOYMENT_TARGETS`. |
| `scripts/lib/robot-id.sh` | Robot identity resolution helper. Sourced by bootstrap and `positronic.sh`. Resolution order: `--robot` flag, `/etc/phantomos/robot`, `host-config.yaml:robot`, `$(hostname)`. |
| `scripts/configure-k0s-containerd-mirror.sh` | Configures `/etc/k0s/containerd.toml` to mirror DockerHub through the local registry. Run during phase 4 (host). |
| `scripts/configure-k0s-nvidia-runtime.sh` | Adds the nvidia container runtime to k0s containerd config. Skipped on hosts without a GPU. |
| `scripts/positronic.sh` | Operator helper for pushing positronic-control + phantom-models images to the local registry; not part of the bringup path. |
| `scripts/validate-local-registry.sh` | Final phase smoke test: registry reachable, expected tags present. |
| `host-config-templates/_template/host-config.yaml` | Annotated schema reference. Operators copy + edit, or `configure-host.sh` derives from it. |
| `host-config-templates/_template/phantomos-app.yaml.tpl` | ArgoCD Application CR template. Substitutions: `{{ROBOT}}`, `{{STACK}}`, `{{REPO_URL}}`, `{{TARGET_REVISION}}`, `{{SELF_HEAL}}`. |
| `host-config-templates/_template/operator-ui-pairing.yaml` | Reference for the operator-ui pairing ConfigMap (AI_PC_URL). |
| `manifests/base/<workload>/` | Universal workload manifests. Deployments/DaemonSets here carry only kernel/runtime mounts (`/dev`, `/dev/shm`, `/tmp`); EVERY other host path is host-injected. |
| `manifests/stacks/core/kustomization.yaml` | Required stack. Bundles `runtime-classes`, `registry`, `dma-video`, `positronic`, `phantomos-api-server`, `yovariable-server`. |
| `manifests/stacks/operator/kustomization.yaml` | Toggleable stack. Bundles `argus`, `nimbus` (operator UI + episode storage). |
| `terraform/main.tf` | Installs the argocd Helm chart. Does NOT apply Application CRs — those are rendered + applied by bootstrap from the per-host template. |
| `docs/rfcs/0001-fleet-control-plane.md` | Long-term destination: fleet control plane queried by serial. |

## 4. Files on the host (`/etc/phantomos/*`)

Everything in this directory is **per-device** and not in git.

| Filename | Purpose | Written by | Read by |
| --- | --- | --- | --- |
| `robot` | One-line robot identity (DNS-1123). Persisted at first bringup so subsequent runs don't need `--robot`. | `bootstrap-robot.sh` (`persist_robot`) | `bootstrap-robot.sh`, `positronic.sh`, any tool sourcing `scripts/lib/robot-id.sh` |
| `host-config.yaml` | Single per-host source-of-truth. Robot identity, AI PC URL, target revision, production flag, stack toggles, image overrides, deployment mounts. | `configure-host.sh` (interactive) or operator (manual) or `bootstrap-robot.sh --host-config <path>` (copy) | `bootstrap-robot.sh`, `configure-host.sh`, `host-config.py` |
| `operator-ui-pairing.yaml` | The AI_PC_URL value for the operator-ui pod. Rendered into a ConfigMap in the `argus` namespace. | `bootstrap-robot.sh` phase 6 (`operator_ui_config`) | `kubectl apply` -> `argus/operator-ui-pairing` ConfigMap; operator-ui Deployment via `configMapKeyRef` |
| `phantomos-app-core.yaml` | Rendered ArgoCD Application CR for the `core` stack (`phantomos-<robot>-core`). | `bootstrap-robot.sh` phase 8 (`gitops` -> `_gitops_render_app`) | `kubectl apply -f` |
| `phantomos-app-operator.yaml` | Rendered ArgoCD Application CR for the `operator` stack (`phantomos-<robot>-operator`). Absent when `stacks.operator.enabled: false`. | `bootstrap-robot.sh` phase 8 | `kubectl apply -f` |

```
+----------------------------------------------------------------+
| operator edits          /etc/phantomos/host-config.yaml         |
+----------------------------------------------------------------+
                           |
                           +--------------------------------------+
                           |                                      |
                           v                                      v
       +----------------------------------+   +----------------------------------+
       | bootstrap-robot.sh phase 6     |   | bootstrap-robot.sh phase 8        |
       | renders                          |   | renders one Application per stack |
       | /etc/phantomos/                  |   | /etc/phantomos/                   |
       |   operator-ui-pairing.yaml       |   |   phantomos-app-core.yaml         |
       +----------------------------------+   |   phantomos-app-operator.yaml     |
                           |                   +----------------------------------+
                           v                                      |
       +----------------------------------+                       v
       | kubectl apply -> ConfigMap        |   +----------------------------------+
       | argus/operator-ui-pairing         |   | kubectl apply -> Application CRs  |
       +----------------------------------+   | argocd/phantomos-<robot>-<stack>  |
                                              +----------------------------------+
                                                              |
                                              +---------------+---------------+
                                              | phase 10 image-overrides:    |
                                              |   patch kustomize.images      |
                                              | phase 11 deployments:        |
                                              |   patch kustomize.patches     |
                                              +-------------------------------+
                                                              |
                                                              v
                                                   ArgoCD reconciles workloads
```

## 5. host-config.yaml schema

The schema is canonicalized in `host-config-templates/_template/host-config.yaml`
and validated by `scripts/lib/host-config.py:cmd_validate`. Every field
documented below; types listed are post-YAML-parse.

### Top-level

| Field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `robot` | string (DNS-1123) | yes | — | Robot identity. Lowercase alphanumeric + hyphens, 1..63 chars, alphanumeric at both ends. Flows into Application names: `phantomos-<robot>-<stack>`. |
| `aiPcUrl` | string (URL) | recommended | — | Tailscale URL of the AI PC paired with this robot. Must start with `http://` or `https://`. Rendered into the operator-ui-pairing ConfigMap. |
| `targetRevision` | string | optional | `main` | Branch / tag / SHA the rendered Applications track. Substituted into `{{TARGET_REVISION}}` in the template. |
| `production` | bool | optional | `false` | When `true`, sets `selfHeal: true` on every rendered Application's `syncPolicy.automated` (unless overridden per-stack). Cluster auto-reverts manual edits. |
| `stacks` | mapping | optional | all enabled | Per-stack toggles + `selfHeal` overrides. See below. |
| `images` | list of mappings | optional | empty | Per-host kustomize image overrides. See below. |
| `deployments` | mapping | optional | empty | Per-deployment hostPath mount injections. See below. |

### `stacks`

Mapping from known stack name to settings. Known stacks (`KNOWN_STACKS`):
`core`, `operator`. Required stacks (`REQUIRED_STACKS`): `core` — cannot be
disabled; validation fails if you try.

| Sub-field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `<stack>.enabled` | bool | optional | `true` | When `false`, the stack's Application is deleted on next bootstrap. Setting `core.enabled: false` is rejected. |
| `<stack>.selfHeal` | bool | optional | inherits `production` | Per-stack override of the global production flag. Useful when you want production drift correction on `core` but tolerate manual edits to `operator` during incidents. |

### `images`

List of mappings; each is a kustomize image override.

| Sub-field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes | The image reference declared in the base manifest (e.g. `localhost:5443/positronic-control`). |
| `newTag` | string | yes | The tag this robot should pull. |
| `newName` | string | optional | Replacement image name. When omitted, only the tag changes. |

The list overrides anything declared in `manifests/stacks/<stack>/`. Bootstrap
phase 10 indexes which stack each image belongs to (by running kustomize on
the stack and scanning rendered container image references), then patches
each stack's Application with only the entries it owns.

### `deployments`

Mapping from known deployment name to settings. Known deployments come from
`DEPLOYMENT_TARGETS` in `host-config.py`:

| Deployment | Stack | Kind | Namespace | Container |
| --- | --- | --- | --- | --- |
| `positronic-control` | core | Deployment | positronic | positronic-control |
| `phantomos-api-server` | core | DaemonSet | phantom | api |

Per-entry fields:

| Sub-field | Type | Required | Description |
| --- | --- | --- | --- |
| `<deployment>.privileged` | bool | optional | When `true`, container runs with `securityContext.privileged: true`. Bootstrap emits a yellow warning. |
| `<deployment>.mounts` | list of mappings | optional | hostPath volumes + volumeMounts to inject. |
| `<deployment>.mounts[].host` | absolute path | yes | Host directory. **`~` is rejected** (bootstrap runs as root, `~` would resolve to `/root`). Must start with `/`. |
| `<deployment>.mounts[].container` | absolute path | yes | Mount path inside the container. |
| `<deployment>.mounts[].name` | string | optional | Volume name. Generated as `mount-<i>` if omitted. Duplicates rejected. |

The base manifests under `manifests/base/positronic/` and
`manifests/base/phantomos-api-server/` carry only universal kernel/runtime
mounts (`/dev`, `/dev/shm`, `/tmp`). Every other host path lives in this
section. Leaving a deployment key out reverts the corresponding workload to
its bare base on the next bootstrap.

### Reject rules (validation)

`host-config.py:cmd_validate` enforces:

- `robot` required and non-empty.
- `aiPcUrl` must start with `http://` or `https://` if set.
- `targetRevision` must be a string if set.
- `production` must be `true`/`false` if set.
- `stacks` must be a mapping; only known stack names allowed.
- `stacks.core.enabled: false` rejected (core is required).
- `stacks.<name>.enabled` and `.selfHeal` must be bool.
- `images` must be a list; each entry must be a mapping with both `name` and `newTag`.
- `deployments` must be a mapping; only known deployment keys allowed.
- `deployments.<name>.privileged` must be bool.
- `deployments.<name>.mounts` must be a list of mappings.
- `mounts[].host` and `mounts[].container` must be absolute paths; `~` is rejected.
- Duplicate volume names within one deployment rejected.

### Annotated example

```yaml
# /etc/phantomos/host-config.yaml — fully populated example
robot: mk09                                    # DNS-1123; flows into Application names

aiPcUrl: http://100.124.202.97:5000            # Tailscale URL of the AI PC

targetRevision: feat/per-stack-applications    # branch the rendered Apps track

production: false                              # selfHeal default; per-stack overrides win

stacks:
  core:
    # selfHeal: true        # uncomment to override production for core only
  operator:
    enabled: true
    # selfHeal: false       # uncomment to leave operator-ui drift alone

images:
  - name: localhost:5443/positronic-control    # routed to core stack (kustomize-scan)
    newTag: 0.2.44-cu130
  - name: localhost:5443/phantom-models
    newTag: 2026-04-30
  - name: foundationbot/argus.operator-ui      # routed to operator stack
    newTag: 7af9c2b
  - name: foundationbot/dma-ethercat            # special case: not a stack image;
    newTag: main-latest-aarch64                 # phase 7 reads it directly to
                                                # render the installer Job

deployments:
  positronic-control:
    privileged: false
    mounts:
      - {name: data,        host: /data,                container: /data}
      - {name: data2,       host: /data2,               container: /data2}
      - {name: recordings,  host: /root/recordings,     container: /recordings}
      - {name: torch-hub,   host: /data/torch,          container: /root/.cache/torch/hub}
  phantomos-api-server:
    mounts:
      - {name: operator-ui-repo, host: /opt/argus/operator_ui,
                                 container: /home/operator/repos/argus/operator_ui}
      - {name: phantom-scripts,  host: /opt/phantom/scripts,
                                 container: /opt/phantom/scripts}
```

## 6. Bootstrap phases

`scripts/bootstrap-robot.sh` runs phases in order. With no `--<phase>` flags
on the command line, every phase runs (full bootstrap). With one or more
`--<phase>` flags, only those phases run (selected-phases mode); selected
mode implies `-y`. Targeted overrides (`--skip-nvidia`, `--skip-validate`)
compose with both modes.

| # | Name | Reads | Writes | Flag |
| --- | --- | --- | --- | --- |
| pre | `reset` (only if `--reset`) | running k0s | backups under `*.bak.<ts>`; tears down k0s; **exits** | `--reset` |
| 1 | `preflight` | OS / arch / kernel / disk / sudo / port collisions | nothing | always (no skip flag) |
| 2 | `deps` | apt / network | `/usr/local/bin/{k0s,terraform}`; apt packages | `--deps` |
| 3 | `cluster` | `/etc/k0s/k0s.yaml` (skip if present) | installs k0s controller, starts `k0scontroller`, writes `/root/.kube/config` | `--cluster` |
| 4 | `host` | `lspci`, `/dev/nvidia0` | `/etc/k0s/containerd.toml` (mirror + nvidia runtime); restarts k0s | `--host` |
| 5 | `seed-pull-secrets` | `--dockerhub-secret-file`, `~/.docker/config.json`, existing `phantom/dockerhub-creds` | creates `dockerhub-creds` Secret in `argus`, `dma-video`, `nimbus`, `phantom` | `--seed-pull-secrets` |
| 6 | `operator-ui-config` | `--ai-pc-url` or existing `/etc/phantomos/operator-ui-pairing.yaml` | `/etc/phantomos/operator-ui-pairing.yaml`; ConfigMap `argus/operator-ui-pairing`; rolls operator-ui if changed | `--operator-ui-config` |
| 7 | `install-dma-ethercat` | `host-config.yaml:images` for `foundationbot/dma-ethercat`; `manifests/installers/dma-ethercat/base/job.yaml` | renders `/etc/phantomos/dma-ethercat-installer.yaml` (sed PLACEHOLDER → tag); `kubectl apply -f` (Job, NOT ArgoCD-managed); waits `Complete`; `dpkg -i /var/lib/dma-ethercat-installer/dma-ethercat-*.deb`; `systemctl enable --now dma-ethercat.service`. Failure halts bootstrap with `DMA-ETHERCAT FAILURE` banner — gitops does NOT run | `--install-dma-ethercat` (skip with `--skip-ethercat-install`) |
| 8 | `gitops` | `host-config.yaml` (`robot`, `targetRevision`, `stacks`, `production`); template | `terraform apply` (argocd Helm); `/etc/phantomos/phantomos-app-<stack>.yaml`; `kubectl apply` per stack; waits Synced+Healthy | `--gitops` |
| 9 | `argocd-admin` | argocd CLI | installs `argocd` to `/usr/local/bin/`; resets admin password to `1984` (bcrypt patched into `argocd-secret`); deletes `argocd-initial-admin-secret` | `--argocd-admin` |
| 10 | `image-overrides` | `host-config.yaml:images`; runs kustomize on each enabled stack to map image -> stack | patches each Application's `spec.source.kustomize.images`; triggers sync | `--image-overrides` |
| 11 | `deployments` | `host-config.yaml:deployments`; `DEPLOYMENT_TARGETS` map | patches each Application's `spec.source.kustomize.patches` (one per owning stack); empty `[]` clears prior injection | `--deployments` (legacy alias `--dev-mounts`) |
| 12 | `setup-positronic` (optional) | `--positronic-image`, local Docker | pushes positronic-control image; builds phantom-models; redeploys pod | `--setup-positronic` |
| 13 | `validate` | local registry | nothing (smoke test) | `--validate` |

### Why phase 7 gates phase 8

`dma-ethercat` runs **bare metal**, not in k0s. It owns the EtherCAT
NIC, runs at SCHED_FIFO priority on isolated RT cores, and exposes
shared-memory queues at `/dev/shm/{actuals,desired,errors,...}` that
the `positronic-control`, `dma-video`, and `nimbus` pods read through
`hostIPC: true`. If gitops brings those pods up before the `.deb` is
installed and the service is healthy, they crashloop on missing IPC
and DockerHub rate-limits the namespace inside ten minutes.

Phase 5.7 closes the gate. The installer Job is bootstrap-managed (lives
under `manifests/installers/dma-ethercat/`, deliberately outside any
ArgoCD stack) so it can be force-deleted-and-reapplied on every run
without racing the reconciler — same pattern as `--seed-pull-secrets`.
The Job's only task is copying a baked-in `.deb` from the image to a
hostPath; `dpkg -i` and `systemctl enable --now` happen on the bootstrap
side. Failure raises a `DMA-ETHERCAT FAILURE` banner and short-circuits
the bootstrap, leaving gitops un-run. Operators who installed the `.deb`
manually pass `--skip-ethercat-install` to bypass the gate.

The `foundationbot/dma-ethercat` image is the only entry under
`host-config.yaml:images` that is **not** routed to a stack. Phase 6.7
(image-overrides) silently skips it; phase 7 reads it directly via
the host-config helper and substitutes the tag into the rendered
installer Job before applying.

### Pre-phases (default-on)

Three pre-phases run before phase 1 (preflight) on every bootstrap.
Each is cheap and idempotent on a healthy host; collectively they
ensure the cluster phase doesn't fight a host port collision or a
running realtime service. Skip with `--skip-docker-stop`,
`--skip-stop-services`, `--skip-ethercat-uninstall`.

| Pre-phase | What it does |
| --- | --- |
| `purge_docker` | `docker stop $(docker ps -q)` — stop every running container |
| `stop_existing_services` | walk `systemctl list-unit-files --state=enabled --type=service`; stop+disable any unit name matching `SYSTEM_SERVICE_PATTERNS` (today: `api.*server`, `dma.*ethercat`) |
| `uninstall_ethercat` | stop+disable `dma-ethercat.service`; run `/usr/sbin/dma-ethercat-uninstall` if present. Phase 5.7 reinstalls fresh from the image |

Phase ordering with file I/O:

```
preflight  (no I/O)
   |
   v
deps       --[apt, k0s bin, terraform bin]--> /usr/local/bin/
   |
   v
cluster    --[k0s install]--> /etc/k0s/k0s.yaml + /root/.kube/config
   |
   v
host       --[edits]--> /etc/k0s/containerd.toml
   |
   v
seed-pull-secrets    --[reads]-> ~/.docker/config.json (or fallback)
                     --[creates]-> Secrets in argus, dma-video, nimbus
   |
   v
operator-ui-config   --[reads]-> /etc/phantomos/host-config.yaml (aiPcUrl)
                     --[writes]-> /etc/phantomos/operator-ui-pairing.yaml
                     --[apply]--> ConfigMap argus/operator-ui-pairing
   |
   v
gitops               --[terraform apply]-> argocd Helm chart
                     --[reads]-> host-config.yaml (robot, targetRevision, stacks, production)
                     --[reads]-> host-config-templates/_template/phantomos-app.yaml.tpl
                     --[writes]-> /etc/phantomos/phantomos-app-<stack>.yaml (per enabled stack)
                     --[apply]--> Application phantomos-<robot>-<stack>
   |
   v
argocd-admin         --[fetch CLI; patch argocd-secret with bcrypt(1984)]
   |
   v
image-overrides      --[reads]-> host-config.yaml:images
                     --[scan]--> kustomize build manifests/stacks/<stack> -> image set
                     --[patch]-> Application.spec.source.kustomize.images
   |
   v
deployments          --[reads]-> host-config.yaml:deployments
                     --[render]-> strategic-merge patch per deployment
                     --[patch]-> Application.spec.source.kustomize.patches (per stack)
   |
   v
setup-positronic (optional)
   |
   v
validate
```

## 7. Per-stack Application model

One ArgoCD Application per enabled stack per robot. Names are
`phantomos-<robot>-<stack>`; both Applications carry the labels
`app.kubernetes.io/part-of: phantomos-<robot>` and
`phantomos.foundation.bot/stack: <stack>` so the entire per-robot tree can be
selected with one label query. Each Application points at
`manifests/stacks/<stack>/` in this repo at the configured `targetRevision`.

```
Robot mk09 cluster:

argocd namespace
  +-- Application phantomos-mk09-core
  |     labels: part-of=phantomos-mk09, stack=core
  |     source:
  |       repoURL: <repo>
  |       targetRevision: main
  |       path: manifests/stacks/core
  |       kustomize:
  |         images:   [...]   # injected by phase 10
  |         patches:  [...]   # injected by phase 11
  |     destination: in-cluster, namespace=default (CreateNamespace=true)
  |     syncPolicy.automated.selfHeal: false (production: flag)
  |
  |     reconciles ->
  |       runtime-classes/  (RuntimeClass: nvidia, ...)
  |       registry/         (Deployment + PV/PVC for localhost:5443)
  |       dma-video/        (DaemonSet)
  |       positronic/       (Deployment positronic-control)
  |       phantomos-api-server/ (DaemonSet api)
  |       yovariable-server/    (Deployment)
  |
  +-- Application phantomos-mk09-operator
        labels: part-of=phantomos-mk09, stack=operator
        source:
          repoURL: <repo>
          targetRevision: main
          path: manifests/stacks/operator
          kustomize:
            images:  [foundationbot/argus.operator-ui:7af9c2b, ...]
            patches: []
        destination: in-cluster, namespace=default (CreateNamespace=true)
        syncPolicy.automated.selfHeal: false

        reconciles ->
          argus/   (operator-ui Deployment + Service + ConfigMaps)
          nimbus/  (mongodb StatefulSet, redis, eg-server, postgres)
```

Each child Application stands alone. There is no umbrella "app-of-apps"
parent (Stage D removed it). Disabling a stack via
`stacks.<name>.enabled: false` makes phase 8 delete that Application and its
rendered file; the workloads under it are pruned by ArgoCD because the
Application carries `prune: true`.

## 8. Render flow

End-to-end sequence on first bringup:

```
operator                  configure-host.sh         /etc/phantomos/        bootstrap-robot.sh         Kubernetes / ArgoCD
   |                            |                          |                       |                         |
   |--- run wizard -----------> |                          |                       |                         |
   |                            |--- prompt fields ------->|                       |                         |
   |--- answers ---------->     |                          |                       |                         |
   |                            |--- write yaml ---------->| host-config.yaml      |                         |
   |                            |                          |                       |                         |
   |--- sudo bash bootstrap-robot.sh ------------------------>                     |                         |
   |                            |                          |                       |--- phases 1-5: deps,    |
   |                            |                          |                       |    cluster, host,       |
   |                            |                          |                       |    seed-pull-secrets    |
   |                            |                          |                       |                         |
   |                            |                          |<-- read aiPcUrl ------|                         |
   |                            |                          |--- write op-ui-pair.yaml -->                    |
   |                            |                          |                       |--- kubectl apply CM --->| ConfigMap argus/operator-ui-pairing
   |                            |                          |                       |                         |
   |                            |                          |                       |--- terraform apply ---->| ArgoCD Helm chart installed
   |                            |                          |                       |                         |
   |                            |                          |<-- read robot,       -|                         |
   |                            |                          |    targetRevision,    |                         |
   |                            |                          |    stacks, production |                         |
   |                            |                          |                       |--- render template ---->|
   |                            |                          |--- write phantomos-app-<stack>.yaml             |
   |                            |                          |                       |--- kubectl apply ------>| Application phantomos-<robot>-core
   |                            |                          |                       |                         | Application phantomos-<robot>-operator
   |                            |                          |                       |--- wait Synced+Healthy  |
   |                            |                          |                       |                         |
   |                            |                          |<-- read images list --|                         |
   |                            |                          |                       |--- kustomize-scan ----->| (no API call; local)
   |                            |                          |                       |    each enabled stack   |
   |                            |                          |                       |    -> image-to-stack    |
   |                            |                          |                       |--- kubectl patch app -->| Application.spec.source.kustomize.images
   |                            |                          |                       |    (one per stack)      |
   |                            |                          |                       |--- trigger sync         |
   |                            |                          |                       |                         |
   |                            |                          |<-- read deployments --|                         |
   |                            |                          |                       |--- render strategic-    |
   |                            |                          |                       |    merge patches per    |
   |                            |                          |                       |    deployment, group    |
   |                            |                          |                       |    by owning stack      |
   |                            |                          |                       |--- kubectl patch app -->| Application.spec.source.kustomize.patches
   |                            |                          |                       |                         |
   |                            |                          |                       |--- phase 13: validate -->|
```

ArgoCD then re-runs `kustomize build manifests/stacks/<stack>/` against the
**modified** Application spec. The `kustomize.images` and `kustomize.patches`
fields are folded in at build time, so the workloads emerge with per-host
image tags and per-host volume mounts even though the on-disk kustomize
overlays carry neither.

## 9. Per-host injection mechanics

ArgoCD's Application CR has a `spec.source.kustomize` object with two fields
that bootstrap drives at runtime. Both are arrays inside a single CR; both
are read by ArgoCD's kustomize backend at every reconcile.

### `spec.source.kustomize.images` — image overrides (phase 10)

Each entry is a string of the form `name=newName:newTag` or `name:newTag`.
ArgoCD passes them to `kustomize edit set image` before running the build,
so they override anything in `manifests/stacks/<stack>/kustomization.yaml`.

The interesting question is: which Application gets which image entry?
`host-config.yaml`'s `images:` list is flat — operators write image refs
without saying which stack they belong to. Bootstrap discovers the mapping
itself: it runs `kustomize build manifests/stacks/<stack>/` for each enabled
stack, parses every container's `image:` field, and builds an
image-name -> stack map. Each entry from `host-config.yaml:images` is then
routed to the stack whose rendered output contains that image name. Entries
that match no enabled stack are surfaced as warnings ("unrouted") and
skipped. The patch is a JSON-merge into `spec.source.kustomize.images`,
followed by a sync trigger.

Code: `bootstrap-robot.sh:_build_image_stack_map`, `_stack_for_image`,
`image_overrides`. Helper: `host-config.py:cmd_get_images_json`.

**Special case: `foundationbot/dma-ethercat`.** This image is the one
entry under `host-config.yaml:images` that is *not* routed to a stack.
Phase 6.7 silently skips it (the routing helper carries a
`NON_STACK_IMAGES` skip-set). Instead, phase 7 (`install-dma-ethercat`)
reads the tag directly via the host-config Python helper and
substitutes it into the rendered installer Job at
`/etc/phantomos/dma-ethercat-installer.yaml`. The Job is
bootstrap-managed (under `manifests/installers/dma-ethercat/`, outside
any kustomize stack) so ArgoCD never touches it.

### `spec.source.kustomize.patches` — strategic-merge patches (phase 11)

Each entry is a `{target, patch}` mapping where `target` selects the
resource (kind/name/namespace) and `patch` is a YAML strategic-merge
document. ArgoCD applies them after image overrides during build.

Routing is **declarative**, not scanned: `DEPLOYMENT_TARGETS` in
`host-config.py` hard-codes which stack owns each known deployment.
`positronic-control` -> `core`, `phantomos-api-server` -> `core`. Adding a
new deployment routing target is a one-entry change to that dict.

For each enabled deployment under `host-config.yaml:deployments`, the
helper renders a strategic-merge patch that injects `volumes:` and
`volumeMounts:` (and, optionally, `securityContext.privileged: true`) into
the target Pod template. All patches for one stack are bundled into that
stack's Application as a single array. **An empty array is set explicitly
when a stack has no deployments configured**, which clears any
previously-injected mounts. Re-running bootstrap with fewer mounts in
host-config reverts the cluster to that smaller set.

Code: `bootstrap-robot.sh:deployments_phase`. Helper:
`host-config.py:cmd_get_deployment_patches_json`, `_build_deployment_patch`.

### Why this survives reconciliation

A naive concern: ArgoCD reconciles toward the manifest in git, so
patches injected via `kubectl patch app` should drift away. They don't,
because the patch targets the **Application CR itself** (not a workload
manifest), and ArgoCD's source-of-truth for an Application is what's in
the cluster, not in git. The injected `kustomize.images` and
`kustomize.patches` fields are present on every read of the Application,
so every kustomize build at sync time picks them up. Bootstrap re-asserts
them on every run, which heals the case where someone has manually
`kubectl edit`'d an Application back to a smaller set of overrides.

## 10. Idempotency and self-skip

Re-running `bootstrap-robot.sh` with no flags is safe and the recommended
way to apply host-config changes. Each phase self-skips on prior state:

- **deps**: `command -v k0s` and `command -v terraform`. Skipped if both binaries are present.
- **cluster**: `[ -e /etc/k0s/k0s.yaml ] && systemctl is-active k0scontroller`. Skipped if both true.
- **host**: `containerd_mirror_already_configured` and `nvidia_runtime_already_configured` greps in `/etc/k0s/containerd.toml`.
- **seed-pull-secrets**: `kubectl get secret dockerhub-creds -n <ns>` for each target namespace.
- **operator-ui-config**: skipped if no `--ai-pc-url` and no existing pairing file (and no `host-config.yaml` to derive from).
- **gitops**: `terraform plan` no-op when chart is current; `kubectl apply` is server-side-merged, so re-applying the same Application is a no-op except for the timestamp.
- **argocd-admin**: always re-patches the bcrypt hash — cheap and ensures the password is whatever `1984` resolves to with current bcrypt cost.
- **image-overrides**: `kubectl patch` is a JSON-merge; an unchanged patch is a no-op; the post-patch `sync` is harmless if nothing changed.
- **deployments**: same as image-overrides; explicitly clearing on every run is intentional so dropping a key in host-config drops the mount.
- **validate**: read-only.

`selfHeal` defaults to `false`. Setting `production: true` (or
`--production`) flips it to `true`, which makes ArgoCD auto-revert any
manual `kubectl edit` to a workload back to whatever the kustomize build
produces. Per-stack `stacks.<name>.selfHeal` overrides the global flag.

The `--reset` flag is the one **non-idempotent** operation: it tears down k0s,
backs up state files, and exits. It exists so a clean rebuild requires a
deliberate two-pass invocation.

## 11. Migration history

The repo passed through six staged migrations (Stage A through Stage F)
on the way to its current shape. Each stage was a feature branch shipped
through PR review.

**Stage A — robot identity in git.**
First cut: `manifests/robots/<name>/kustomization.yaml` per robot, hand-edited.
Each robot's overlay was checked in; bringup did `kubectl apply -k manifests/robots/<name>`.
Worked for two devices, broke for ten — every robot needed a PR to land.

**Stage B — ArgoCD app-of-apps.**
Replaced the ad-hoc `kubectl apply -k` with an ArgoCD root Application
(`gitops/apps/<robot>/root.yaml`) that fanned out to a child Application per
workload (positronic, dma-video, registry, ...). Sync became automated; per-robot
config was still in git, still per-robot directories.

**Stage C — host-config.yaml introduced.**
`/etc/phantomos/host-config.yaml` landed alongside the per-robot directories.
First fields: `robot`, `aiPcUrl`. The wizard `configure-host.sh` was added.
The `phantomos-api-server` operator-ui ConfigMap stopped being templated into
git and became a derived file under `/etc/phantomos/`. Reduced PR pressure but
didn't eliminate per-robot directories yet.

**Stage D — Application CR rendered per-host.**
`gitops/apps/<robot>/` was deleted from git. The Application CR template
moved to `host-config-templates/_template/phantomos-app.yaml.tpl`. Bootstrap
phase 8 started rendering it with sed substitutions and applying the result
from `/etc/phantomos/phantomos-app.yaml`. Repo lost the umbrella-app reference
to robot identity. Stage D was the first version of the codebase where adding
a new robot did not require a git commit.

**Stage E — image-overrides + dev-mode mounts.**
Per-host kustomize image tags moved into `host-config.yaml:images` and were
injected into the live Application via `spec.source.kustomize.images` (phase 10).
First cut of mount injection landed as `host-config.yaml:devMode` (single
flat list of dev-only mounts on positronic-control). Same patch path
(`spec.source.kustomize.patches`), narrower schema.

**Stage F — per-stack Applications + general deployments schema.**
The single umbrella `phantomos-<robot>` Application split into per-stack
children: `phantomos-<robot>-core` and `phantomos-<robot>-operator`. Stacks
became toggleable (`stacks.<name>.enabled`). The `devMode:` block was
replaced with `deployments:`, a general per-deployment mount schema indexed
by the new `DEPLOYMENT_TARGETS` registry — `phantomos-api-server` joined
`positronic-control` as a host-configurable workload. Base manifests were
trimmed back to kernel/runtime mounts only (`/dev`, `/dev/shm`, `/tmp`); every
other host path is now per-host. Bootstrap gained `--seed-pull-secrets` as a
first-class phase. The cluster phase moved before the host phase (k0s has to
have run once for `/etc/k0s/containerd.toml` to exist before host config
edits it).

**Where it's heading.**
Stage F's surface area is what RFC 0001 is designed to preserve: the
**fleet control plane** will replace the on-device `host-config.yaml` with
a control-plane API queried by hardware serial at bringup. The same fields,
the same Application CR template, the same kustomize injections — different
backing store. See [RFC 0001 — Fleet control plane](./rfcs/0001-fleet-control-plane.md).

## 12. How to extend

### Add a new stack

1. Create `manifests/stacks/<name>/kustomization.yaml`. List the bases under it.
   Set `labels` with `phantomos.foundation.bot/stack: <name>` and
   `includeSelectors: false` (selectors on existing Deployments are immutable).
2. Append `<name>` to `KNOWN_STACKS` in `scripts/lib/host-config.py`. Add to
   `REQUIRED_STACKS` only if disabling the stack should be rejected.
3. Add a default block under `stacks:` in
   `host-config-templates/_template/host-config.yaml` so the schema example
   shows the new toggle.
4. Bootstrap renders+applies it automatically on next run because it iterates
   `cmd_get_enabled_stacks`. No bootstrap code change needed.

### Add a deployment target (host-configurable mounts)

1. Edit `DEPLOYMENT_TARGETS` in `scripts/lib/host-config.py`. Add an entry:
   ```python
   "<deployment-name>": {
       "stack": "<owning-stack>",
       "kind": "Deployment" | "DaemonSet" | "StatefulSet",
       "namespace": "<ns>",
       "container": "<container-name-in-pod-template>",
   }
   ```
2. Make sure the matching base manifest under `manifests/base/<workload>/`
   declares only kernel/runtime mounts. Per-host paths come from the schema.
3. Update the `Known deployment keys` comment in
   `host-config-templates/_template/host-config.yaml`.
4. The new deployment is now host-configurable. No bootstrap or wizard
   change needed unless you want a `configure-host.sh` prompt for it
   (search for `phantomos-api-server mounts` in `configure-host.sh` for the
   pattern).

### Add a host-config field

1. Edit `host-config-templates/_template/host-config.yaml` to document the
   new field.
2. Add a `cmd_get_<field>` (or extend `cmd_get`) in `scripts/lib/host-config.py`
   if the bootstrap shell needs to read it, plus validation in `cmd_validate`.
3. Wire it into the relevant phase in `scripts/bootstrap-robot.sh`.
4. Optionally add a wizard prompt in `scripts/configure-host.sh`.

### Replace placeholder image tags (per device, no repo change)

1. Edit `/etc/phantomos/host-config.yaml:images` on the device.
2. Run `sudo bash scripts/bootstrap-robot.sh --image-overrides`.
3. ArgoCD sync is triggered automatically; tags propagate to the cluster
   without a git commit.

## 13. References

- [RFC 0001 — Fleet control plane](./rfcs/0001-fleet-control-plane.md) — long-term direction.
- [Operations runbook](./operations.md) — operator runbook + troubleshooting.
- `manifests/` — universal workload definitions and stack kustomize roots.
- `scripts/lib/host-config.py` — schema definition (the dataclass-equivalent),
  `KNOWN_STACKS`, `REQUIRED_STACKS`, `DEPLOYMENT_TARGETS`.
- `scripts/lib/robot-id.sh` — robot identity resolution rules.
- `host-config-templates/_template/host-config.yaml` — annotated schema example.
- `host-config-templates/_template/phantomos-app.yaml.tpl` — Application CR template.
