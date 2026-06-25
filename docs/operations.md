# Operations runbook

Day-to-day operator's guide for the Phantom-OS k0s + ArgoCD fleet.
Covers first bringup, ongoing operations, migration scenarios, and
troubleshooting. For architecture and the *why*, see
[architecture.md](./architecture.md).

## Glossary

- **robot** — physical device; DNS-1123 name (`mk09`, `mk11000010`).
- **stack** — a kustomize root under `manifests/stacks/<name>/`. The
  fleet currently ships `core` and `operator`.
- **deployment** — a Kubernetes Deployment that the host injects
  per-host mounts into. Today: `positronic-control` (core stack),
  `phantomos-api-server` (core stack).
- **Application** — an ArgoCD `Application` CR. Per-robot, per-stack:
  `phantomos-<robot>-core`, `phantomos-<robot>-operator`.
- **host-config.yaml** — `/etc/phantomos/host-config.yaml`, the per-host
  source-of-truth. Robot id, AI PC URL, target revision, production
  toggle, stack toggles, image overrides, deployments mounts.
- **production mode** — `production: true` (or `--production`); ArgoCD
  Applications get `selfHeal: true` and auto-revert manual cluster
  edits.
- **deployments: schema** — current per-host hostPath mount schema
  (replaces the legacy `devMode:` block).

Flag style: `--<phase>` selects a single phase (selected-phases-only
mode). `--skip-nvidia` is a targeted override that composes with both
selected-phases and full-bootstrap modes.

## Table of contents

1. [First bringup](#1-first-bringup)
2. [Verify](#2-verify)
3. [Day-2 operations](#3-day-2-operations)
4. [Bootstrap phases reference](#4-bootstrap-phases-reference)
5. [Per-phase invocations cheat sheet](#5-per-phase-invocations-cheat-sheet)
6. [Migration scenarios](#6-migration-scenarios)
7. [Troubleshooting](#7-troubleshooting)
8. [Reference: filesystem map and commands](#8-reference)

---

## 1. First bringup

### Sequence overview

```
+----------+     +-------------------+     +-------------------+     +-----------+
|  laptop  | SSH |   robot (fresh)   |     | configure-host.sh |     | bootstrap |
|          | --> |  user@<robot-ip>  | --> |  (interactive)    | --> |  -robot   |
+----------+     +-------------------+     +-------------------+     +-----------+
                          |                          |                     |
                          | git clone                | writes              | k0s install
                          | /opt/Phantom-OS-Kuber... | /etc/phantomos/     | terraform apply
                          |                          | host-config.yaml    | argo apps applied
                          v                          v                     v
                  ready to configure         ready to bootstrap      cluster up + synced
```

### 1.1 SSH and clone

```bash
ssh user@<robot-ip>
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git \
  /opt/Phantom-OS-KubernetesOptions
cd /opt/Phantom-OS-KubernetesOptions
```

If the robot already has the repo:

```bash
cd /opt/Phantom-OS-KubernetesOptions
sudo git pull
```

### 1.2 Checkout the right branch

Most fleets track `main`. To bring a robot up on a feature branch
(e.g. you're staging a manifest change):

```bash
sudo git fetch origin
sudo git checkout <branch>
```

The branch you check out is what bootstrap reads templates from.
The `targetRevision:` field in `host-config.yaml` is what ArgoCD
itself tracks at runtime — those two can differ if you want bootstrap
to use latest scripts but ArgoCD pinned to a specific revision.

### 1.3 Run the wizard

```bash
sudo bash scripts/configure-host.sh
```

The wizard reads any existing `/etc/phantomos/host-config.yaml` as the
seed and prompts for each field. Press enter to keep a default, or
type a new value.

#### Seeding from a template (`--from-template`)

A fresh robot has no `/etc/phantomos/host-config.yaml`, so the wizard
falls back to the generic `host-config-templates/_template/` defaults —
every field starts blank. To pre-fill the prompts from a known-good
config (another robot's values, or a team-canonical template), pass
`--from-template`:

```bash
# by name -> host-config-templates/<name>/host-config.yaml in this repo
sudo bash scripts/configure-host.sh --from-template mk09

# by directory -> <dir>/host-config.yaml
sudo bash scripts/configure-host.sh --from-template ~/phantom-fleet-config/mk11000019

# by file -> use that YAML directly
sudo bash scripts/configure-host.sh --from-template ~/configs/base.yaml
```

The chosen template only **seeds** the prompts — the wizard still walks
every field so you can adjust the robot-specific ones (id, AI PC URL,
core pinning). The seed precedence is:

1. `--from-template <name|dir|file>` (when given)
2. existing `/etc/phantomos/host-config.yaml`
3. `host-config-templates/<hostname>/host-config.yaml`
4. `host-config-templates/_template/host-config.yaml`

This is the fast path for bringing up a robot identical to an existing
one: point `--from-template` at the sibling's config tree, then change
only the identity and pinning fields. (The repo ships only
`_template/`; per-robot template trees are operator-supplied, e.g. a
`phantom-fleet-config/` checkout.)

#### Wizard prompts

**Robot identity** — DNS-1123 name. Used in Application names
(`phantomos-<robot>-core`, etc.).

```
== robot identity ==
  e.g. mk09, ak-007, mk11000010
  robot []: mk09
```

The wizard rejects names that aren't DNS-1123. If you mistype,
re-run the wizard or pass `--robot <name>` to bootstrap directly.

**AI PC URL** — Tailscale URL of the AI PC paired with this robot.
Used by the operator UI for inference.

```
== AI PC pairing ==
  e.g. http://100.124.202.97:5000
  aiPcUrl []: http://100.124.202.97:5000
```

**targetRevision** — branch / tag / SHA the per-host ArgoCD
Applications track. Default: `main`.

```
  targetRevision [main]:
```

**Production toggle** — when `true`, every Application gets
`selfHeal: true` and ArgoCD auto-reverts manual `kubectl edit`
commands. When `false`, drift is reported but not corrected.

```
  production [false]:
```

**Stack toggles** — for each stack, whether to enable it on this
robot, and the optional per-stack `selfHeal` override. The `core`
stack is always enabled (cannot be disabled).

```
== stacks ==
  stacks.operator.enabled [true]:
  stacks.operator.selfHeal []:    # blank = inherit production:
  stacks.core.selfHeal []:        # blank = inherit production:
```

**Image tag overrides** — per-host kustomize image overrides.
Bootstrap injects these into the live Application at phase
`--image-overrides`. Press enter to keep, or type a new tag.

```
== image tag overrides ==
  foundationbot/positronic-control tag [0.2.44-production-cu130]:
  foundationbot/phantom-models tag [2026-04-30]:
  foundationbot/argus.operator-ui tag [<sha>]:
```

**Deployments mounts** — per-host hostPath mounts. The wizard
offers two presets:

- **Production preset** — `/data`, `/data2`, `/root/recordings`,
  `/data/torch` mounted into `positronic-control`. `privileged: false`.
- **Dev preset** — production paths plus the developer's checkout
  at `/src`, the IHMC config, and `trainground`. `privileged: true`.

You can also choose **none** (bare base manifests) or **custom** to
hand-edit the YAML afterwards. The schema lives at
`host-config-templates/_template/host-config.yaml`.

### 1.4 Run bootstrap

```bash
sudo bash scripts/bootstrap-robot.sh
```

With no `--<phase>` flag, every phase runs in sequence (see
[section 4](#4-bootstrap-phases-reference)). Takes 5-10 minutes on
a fresh machine. Each phase prints `PASS`, `FAIL`, or `SKIP`. The
script bails at the first `FAIL` unless `--keep-going` is set.

The wizard offers to chain into bootstrap when it finishes — answer
`y` to skip the manual second command:

```
  Run bootstrap-robot.sh now? [y/N]: y
```

---

## 2. Verify

After bootstrap returns, confirm the cluster is healthy.

### 2.1 kubectl checks

```bash
# Every pod should eventually be Running. Init:ImagePullBackOff means
# the image override didn't apply or the dockerhub-creds pull secret is
# missing in the namespace.
sudo k0s kubectl get pods -A

# Both Applications should be Synced + Healthy.
sudo k0s kubectl -n argocd get applications

# operator-ui should have the AI_PC_URL you set.
sudo k0s kubectl -n argus exec deploy/operator-ui -- env | grep AI_PC_URL

# positronic-control mounts should match host-config.yaml deployments:.
sudo k0s kubectl -n positronic get deploy positronic-control -o yaml \
  | grep -A2 hostPath
```

### 2.2 UIs

Operator UI (NodePort):

```
http://<robot-ip>:30080
```

ArgoCD UI (port-forward; not exposed by default):

```bash
sudo k0s kubectl -n argocd port-forward svc/argocd-server 8080:443 &
# open https://localhost:8080
# user: admin
# pass: 1984 (or whatever you set in --argocd-admin)
```

### 2.3 positronic.sh status

```bash
bash scripts/positronic.sh status
```

Reports pod state, QoS class, `PHANTOM_CMD`, PID 1, the live hostPath
mounts, and the deployments-intent block from host-config.yaml.

---

## 3. Day-2 operations

For each common change: edit `host-config.yaml`, then run the
appropriate single-phase bootstrap invocation.

```
edit /etc/phantomos/host-config.yaml
            |
            v
+-----------------------------+
|  what did you change?       |
+-----------------------------+
   |        |       |       |       |       |
aiPcUrl  images  deploy- stacks. production targetRevision
                  ments   <x>.    /selfHeal   /branch
                          enabled
   |        |       |       |       |       |
   v        v       v       v       v       v
--operator-ui-config
        --image-overrides
                --deployments
                        --gitops
                                --gitops    --gitops
```

### 3.1 Re-pair AI PC

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# update aiPcUrl: http://<new-ip>:5000

sudo bash scripts/bootstrap-robot.sh --operator-ui-config
```

The phase re-renders `/etc/phantomos/operator-ui-pairing.yaml`,
applies the ConfigMap, and rolls the operator-ui Deployment so the
new value takes effect.

### 3.2 Bump image tags

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# update images: newTag values

sudo bash scripts/bootstrap-robot.sh --image-overrides
```

This patches `spec.source.kustomize.images` on every relevant
Application. ArgoCD re-syncs within ~3 min, or annotate to force:

```bash
sudo k0s kubectl -n argocd annotate app phantomos-<robot>-core \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 3.3 Add or remove a deployments mount

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# add/remove entries under deployments.<name>.mounts

sudo bash scripts/bootstrap-robot.sh --deployments
```

Bootstrap renders strategic-merge patches into the matching stack's
Application via `spec.source.kustomize.patches`. Removing a key from
`host-config.yaml` and re-running this phase clears the patch — the
pod reverts to its bare base.

The legacy alias `--dev-mounts` is still accepted and behaves
identically.

### 3.4 Toggle the operator stack off

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# stacks.operator.enabled: false

sudo bash scripts/bootstrap-robot.sh --gitops
```

Phase `--gitops` re-renders every Application. Disabling a stack
deletes the corresponding Application; ArgoCD's cascade prune
removes the namespaces and workloads.

### 3.5 Rotate the ArgoCD admin password

```bash
sudo bash scripts/bootstrap-robot.sh --argocd-admin
```

The phase prompts interactively. Press enter (empty input) for the
fleet default `1984`, or type a new password. The argocd-secret is
patched with a fresh bcrypt hash, and the
`argocd-initial-admin-secret` is removed.

### 3.6 Switch to production mode

Two equivalent paths:

Persist the choice in host-config.yaml:

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# production: true
sudo bash scripts/bootstrap-robot.sh --gitops
```

Or override for a single run via the CLI flag:

```bash
sudo bash scripts/bootstrap-robot.sh --gitops --production
```

`--production` / `--no-production` override `host-config.yaml`'s
`production:` field for that invocation only. Persisted state lives
in the rendered Application CR on the cluster.

### 3.7 Pull a new branch

```bash
cd /opt/Phantom-OS-KubernetesOptions
sudo git pull

sudo bash scripts/bootstrap-robot.sh
```

The full re-run is idempotent. Phases that detect "already done"
state print `SKIP`. Use this whenever `bootstrap-robot.sh` itself or
the templates change.

If you only need to point ArgoCD at a new branch (and not pick up
script changes), edit `targetRevision:` in `host-config.yaml` and
run `--gitops` instead.

### 3.8 Bump dma-ethercat installer image

The bare-metal `dma-ethercat` service is installed by phase 12 from a
`.deb` baked into the `foundationbot/dma-ethercat` container image. To
roll a new version of the realtime stack:

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# under images:, set or update:
#   - name: foundationbot/dma-ethercat
#     newTag: <new-tag>     # e.g. main-latest-aarch64

sudo bash scripts/bootstrap-robot.sh --install-dma-ethercat
```

The phase deletes any prior `dma-ethercat-installer` Job, re-renders
`/etc/phantomos/dma-ethercat-installer.yaml` from
`manifests/installers/dma-ethercat/base/job.yaml` with the new tag,
applies it, waits for the Job to copy the `.deb` to
`/var/lib/dma-ethercat-installer/`, runs `dpkg -i`, and re-enables
`dma-ethercat.service`. Halts with a `DMA-ETHERCAT FAILURE` banner on
any failure — gitops does NOT run on a failed install, so a broken
realtime stack can't bring up the pods that depend on it.

Tag conventions:
- `…-latest-aarch64` — Jetson / arm64 robots
- `…-latest-amd64`   — x86 robots
- timestamped CI tags for known-good pins (e.g. `…-20260126T191500-aarch64`)

### 3.9 Rotate DockerHub PAT

See [`dockerhub-creds.md`](./dockerhub-creds.md) for the full PAT
rotation runbook. Short version: re-`docker login`, then re-run
`bootstrap-robot.sh --seed-pull-secrets` to propagate the refreshed
`dockerhub-creds` Secret to every namespace that pulls private images.

### 3.10 Toggle an optional workload on a robot

Optional DaemonSets gate on `foundation.bot/has-X=true` node labels.
Bootstrap reconciles the `foundation.bot/` label namespace from
`host-config.yaml`'s `nodeLabels:` block on every cluster-phase run.

Known labels and the workloads they gate:

| Label | Workload | Default |
|---|---|---|
| `foundation.bot/has-positronic` | `positronic-control` Deployment | **on** |
| `foundation.bot/has-locomotion` | `phantom-locomotion` DaemonSet | off |
| `foundation.bot/has-sonic` | `phantom-sonic` DaemonSet (Walking ↔ SONIC) | off |
| `foundation.bot/has-state-estimator` | `cpp-robot-state-estimator` DaemonSet | off |
| `foundation.bot/has-recorder` | `dma-recorder` DaemonSet | off |
| `foundation.bot/has-streamer` | `rerun-streamer` DaemonSet | off |
| `foundation.bot/has-ik-mk2` | `ik-mk2` DaemonSet (upper-body IK shim, `positronic` ns) | off |

`has-positronic` is **default-on** — the cluster phase reconciler
injects it on every robot unless host-config explicitly sets it
`"false"`. Migrating a robot from positronic to locomotion/sonic is a
two-label change.

**positronic, locomotion, and sonic are mutually exclusive** — each
drives `/desired`, so the validator rejects enabling more than one. In
particular, setting only `has-locomotion: "true"` or `has-sonic: "true"`
is rejected because positronic is still on by default; you must also set
`has-positronic: "false"` in the same edit.

### Recorders (dma-streams) — arming behavior

`dma-streams` ships three distinct workloads with **different** record
triggers — there is no single "dma.streams recording" switch:

| Workload | Records | Arming |
|---|---|---|
| `dma-recorder` (`has-recorder`) | EtherCAT IPC queues (`/actuals`, `/desired`, …) → `.rrd` | gates on the bus being **OPERATIONAL**; `--manual-arm` (in args) additionally requires an explicit `RECORDING_START` opcode on `/commands`. **Remove `--manual-arm` → always-armed**: auto-records as soon as the bus is operational, no operator trigger. |
| `dma-video-recorder` (`has-video-recorder`) | camera streams → `.rrd` | **Automatic, no arm flag** — reads `/motor_diagnostics` and records while ≥1 EtherCAT slave is operational; it follows the bus (no `RECORDING_START`/`STOP`). |
| `rerun-streamer` (`has-streamer`) | live Rerun stream (not a recorder) | n/a |

So "auto-record" only ever concerned **`dma-recorder`** — `dma-video-recorder`
was already automatic. Both write to `/root/recordings`; each has a `janitor`
sidecar that bounds disk (retention days + folder-size cap), so always-armed
recording is disk-safe. Trigger/stop a `--manual-arm` `dma-recorder` from any
host with kubectl:

```
POD=$(kubectl -n phantom get pod -l app.kubernetes.io/name=dma-recorder -o name | head -1)
kubectl -n phantom exec -c recorder $POD -- dma-cmd record start   # ... stop
```

Enable a default-off workload on `<robot>`:

1. Edit `/etc/phantomos/host-config.yaml`, add to `nodeLabels:`:
   ```yaml
   nodeLabels:
     foundation.bot/has-state-estimator: "true"
   ```
2. Re-run the cluster phase:
   ```bash
   sudo bash scripts/bootstrap-robot.sh --cluster -y
   ```
   Bootstrap calls `kubectl label node` for every entry and removes any
   `foundation.bot/*` label on the node that's no longer in the block.
3. The DaemonSet's controller picks up the new label within seconds
   and schedules a pod.

Migrate `<robot>` from positronic to locomotion:

```yaml
nodeLabels:
  foundation.bot/has-positronic: "false"
  foundation.bot/has-locomotion: "true"
```

```bash
sudo bash scripts/bootstrap-robot.sh --cluster -y
```

Migrate `<robot>` to the Walking ↔ SONIC stack (clear both competing
drivers, enable sonic):

```yaml
nodeLabels:
  foundation.bot/has-positronic: "false"
  foundation.bot/has-locomotion: "false"
  foundation.bot/has-sonic: "true"
```

```bash
sudo bash scripts/bootstrap-robot.sh --cluster --sonic-config -y
```

`--sonic-config` also renders the `phantom-sonic-config` ConfigMap from
the optional `phantomSonic:` block (ROS domain, walking policy, encoder
mode, ZMQ/web ports, ramp). See [§3.11](#311-phantom-sonic-walking--sonic)
for operating it.

To disable a default-off workload: remove the entry and re-run the
cluster phase. To disable positronic without enabling locomotion/sonic:
set `foundation.bot/has-positronic: "false"` (no robot will be running a
controller until you also enable one of the others).

Bootstrap only manages the `foundation.bot/` prefix. Labels outside
that prefix (`kubernetes.io/*`, k0s built-ins, ad-hoc operator labels)
are never touched.

---

### 3.11 phantom-sonic (Walking ↔ SONIC)

The `phantom-sonic` DaemonSet runs the MK1 Walking ↔ SONIC stack as a
**single pod with four containers** (gated on `foundation.bot/has-sonic`,
see [§3.10](#310-toggle-an-optional-workload-on-a-robot) to enable):

| Container | Image | Role |
|---|---|---|
| `control` | `phantom-dma-inference` | joystick + mode-manager FSM (IDLE/WALKING/SONIC); owns `/dev/input` |
| `walking` | `phantom-dma-inference` | MK1 walking IMU policy (`mk1-walking-1imu-1`); boots idle |
| `sonic` | `phantom-dma-inference` | SONIC whole-body policy; gated off until engaged |
| `motion-replay` | `phantom-motion-replay` | web UI (:7865) + ZMQ motion streamer (:5557); clips baked in |

The three inference containers share the `phantom-dma-inference` image,
rewritten from `host-config.yaml`'s `images.phantom-locomotion` entry
(same published image — one kustomize find-key serves both workloads).
`motion-replay` is rewritten from `images.phantom-motion-replay`.

**Joystick:** X = start walking · Triangle = toggle walking ↔ SONIC ·
Square+Triangle = kill to idle. Boots **idle** (nothing commands the
robot until you press X).

**Dependency:** the policy nodes attach to DMA.ethercat's `/dev/shm` IPC
queues (`/actuals`, `/desired`, …). DMA.ethercat (the bare-metal
`dma-ethercat.service`) must be running first, or `walking`/`sonic` will
CrashLoop on `shm_open failed` — see
[§7.18](#718-phantom-sonic-walkingsonic-crashloop-on-shm_open).

**Per-host options** (`phantomSonic:` block → `phantom-sonic-config`
ConfigMap, applied by `--sonic-config`):

```yaml
phantomSonic:
  rosDomainId: "43"             # ROS_DOMAIN_ID (control + walking)
  walkingPolicy: mk1-walking-1imu-1
  encoderMode: "0"              # sonic --encoder-mode
  motionZmqPort: "5557"
  controlZmqPort: "5558"
  webPort: "7865"               # motion-replay UI
  motionRampSecs: "1.0"
```

All fields optional; omitted ones fall back to the defaults shown. After
editing, apply with `sudo bash scripts/bootstrap-robot.sh --sonic-config`
(rolls the DaemonSet to pick up the new ConfigMap).

**Convenience commands** ([`positronic.sh`](../scripts/positronic.sh)):

```bash
bash scripts/positronic.sh sonic status              # DaemonSet + 4-container state
bash scripts/positronic.sh sonic logs walking -f     # per-container logs
bash scripts/positronic.sh sonic logs                # all containers, prefixed
bash scripts/positronic.sh sonic exec sonic          # shell into a container
bash scripts/positronic.sh sonic restart             # roll the DaemonSet
bash scripts/positronic.sh sonic web                 # print the UI URL
```

### 3.12 rerun-streamer (live web visualisation)

The `rerun-streamer` DaemonSet hosts the live web view at
`http://<robot>:9788` and the gRPC ingest at `:9877`. Off by default —
enable per host by setting `foundation.bot/has-streamer: "true"` under
`nodeLabels:` in `/etc/phantomos/host-config.yaml`, then rerun
bootstrap (see [§3.10](#310-toggle-an-optional-workload-on-a-robot)).
Manifest:
[`manifests/base/dma-streams/rerun-streamer.yaml`](../manifests/base/dma-streams/rerun-streamer.yaml).

**Operator URL.** Browsers landing on `http://<robot>:9788` without a
query string hit the rerun Welcome page (the WASM viewer doesn't know
which gRPC source to dial — the default points at `localhost:9877`,
which from a remote browser is the operator's laptop, not the robot).
Always use:

```
http://<robot>:9788/?url=rerun+http://<robot>:9877/proxy
```

The streamer's image whitelists the matching origin via
`--cors-allow-origin 'http://*:9788'`.

#### Tuning the live-view publish rate

The shm producer (`dma_main`) writes every queue at the EtherCAT cycle
rate (~482 Hz). The streamer publishes **1 out of every N samples** to
the viewer; the per-host knobs are in the
`deployments.rerun-streamer` block of `host-config.yaml`:

```yaml
deployments:
  rerun-streamer:
    variant: mk2
    queueMemoryLimitMb: 4                # AsyncLogQueue cap (MB)
    motorDiagnosticsDownsample: 125      # /motor_diagnostics-only override
```

The base manifest sets the GLOBAL `--downsample 25`, so:

```
viewer rate = 482 / 25  ≈ 20 Hz   (joints, desireds, controller, …)
```

`motorDiagnosticsDownsample` overrides `--downsample` for the
`/motor_diagnostics` queue ONLY:

| Value | Math | Diagnostics rate |
|---|---|---|
| `0` (or omitted) | inherits `--downsample` (25) | ≈ 20 Hz |
| `25` | 482 / 25 | ≈ 20 Hz (same as inherit; explicit) |
| `125` (recommended) | 482 / 125 | ≈ 4 Hz |
| `500` | 482 / 500 | ≈ 1 Hz |

**Why per-queue knobs exist.** Each `/motor_diagnostics` snapshot
explodes into ~300 Rerun entities (per-motor temperature / fault /
status × ~30 joints + bus counters + per-slave EtherCAT state).
`/state_estimator` adds another ~120 (pelvis 6-DoF + 30 joints + IMU +
F/T + contact). At the joint rate those alone are >9000
series-updates/s — typically larger than the entire joint stream and
enough to saturate the streamer→server gRPC sender. Symptom: high
`gRPC queue dropped:` counter in the streamer's stats lines and holes /
freezes in the live view. Setting `motorDiagnosticsDownsample: 125`
drops that to ~1200 series-updates/s without touching joint
visibility.

**Every high-rate queue has its own knob.** All default to 0 = inherit
`--downsample`; set positive to override:

| Field | Streamer flag | Queue |
|---|---|---|
| `actualsDownsample` | `--actuals-downsample` | `/actuals` |
| `actualsTransformsDownsample` | `--actuals-transforms-downsample` | `/actuals_transforms` |
| `desiredDownsample` | `--desired-downsample` | `/desired` |
| `desiredsControllerDownsample` | `--desireds-controller-downsample` | `/desireds_controller` |
| `desiredsTransformsDownsample` | `--desireds-transforms-downsample` | `/desireds_transforms` |
| `rawImuDownsample` | `--raw-imu-downsample` | `/raw_imu_actuals` |
| `motorDiagnosticsDownsample` | `--motor-diagnostics-downsample` | `/motor_diagnostics` |
| `stateEstimatorDownsample` | `--state-estimator-downsample` | `/state_estimator` |
| `gripperDownsample` | `--gripper-downsample` | `/desired_{left,right}_gripper` |

Event-driven queues (`/errors`, `/commands`, `/command_responses`,
`/motor_params_applied`) are intentionally NOT downsampled — they fire
rarely enough that downsampling them would hide real activity.

**The recorder is unaffected.** It captures every shm sample to `.rrd`
regardless of any of these knobs — downsampling only changes what
reaches the live viewer.

---

### 3.13 Copy a locally-built image to other robots (offline tar transfer)

`phantom-models` and `phantom-policies` are locally-built busybox carrier
images pinned to `localhost:5443/*` — they have no DockerHub upstream and
no containerd mirror fallthrough. Once you have built them on one robot
(see [`scripts/build-images-deb.sh`](../scripts/build-images-deb.sh) and
[`docs/internal/image-flow-and-registry-bootstrap.md`](internal/image-flow-and-registry-bootstrap.md)),
you can move them to other robots as plain tarballs instead of rebuilding
in place. The worked example below uses `phantom-models:2026-06-08` and
`phantom-policies:2026-06-09-sonic-onnx`.

**1. On the source robot — save the images to tarballs.**

```bash
# pull into the local docker daemon first if they aren't already there
docker pull localhost:5443/phantom-models:2026-06-08
docker pull localhost:5443/phantom-policies:2026-06-09-sonic-onnx

docker save localhost:5443/phantom-models:2026-06-08 \
  -o /root/phantom-models-2026-06-08.tar
docker save localhost:5443/phantom-policies:2026-06-09-sonic-onnx \
  -o /root/phantom-policies-2026-06-09-sonic-onnx.tar

# optional: zstd compression (much smaller; load with `zstd -dc | docker load`)
zstd -19 /root/phantom-models-2026-06-08.tar      # -> *.tar.zst
zstd -19 /root/phantom-policies-2026-06-09-sonic-onnx.tar
```

No-docker fallback (skopeo, copies straight from the in-cluster registry
to an OCI archive):

```bash
skopeo copy --src-tls-verify=false \
  docker://localhost:5443/phantom-models:2026-06-08 \
  oci-archive:/root/phantom-models-2026-06-08.tar:phantom-models:2026-06-08
```

**2. Relay to each target robot.** Pull the tarballs to a workstation,
then push them out:

```bash
# on your workstation
scp source-robot:/root/phantom-*.tar .
scp phantom-*.tar target-robot:/root/
```

> **Arch matters.** A `docker save` tarball carries the architecture of
> the robot it was built on — an `arm64` tar only loads on an `arm64`
> target. The workstation is just a relay; it never loads the image, so
> its own arch is irrelevant. Build (or save) on a host whose arch
> matches the target fleet.

**3. On each target robot — load and push into the local registry.**

```bash
docker load -i /root/phantom-models-2026-06-08.tar
docker load -i /root/phantom-policies-2026-06-09-sonic-onnx.tar
# (for *.tar.zst:  zstd -dc /root/phantom-models-2026-06-08.tar.zst | docker load)

docker push localhost:5443/phantom-models:2026-06-08
docker push localhost:5443/phantom-policies:2026-06-09-sonic-onnx
```

Verify the tags landed in the in-cluster registry:

```bash
curl -s http://localhost:5443/v2/phantom-models/tags/list
curl -s http://localhost:5443/v2/phantom-policies/tags/list
```

This load+push step is automated by
[`scripts/load-image-tars.sh`](../scripts/load-image-tars.sh)
(`bash scripts/load-image-tars.sh <tarball> ...` — a pure registry op,
usable off-robot, no `host-config.yaml` knowledge). A full bootstrap can
do the whole thing end-to-end — load+push **and** wire the loaded tag
into `host-config.yaml` — via the `--load-image-tars` phase, which both
loads/pushes the tarballs and updates the `images:` block (so you can
skip step 4 below). Two ways to drive it:

```bash
# Explicit (non-interactive) — give the on-robot tarball paths as flags:
sudo bash scripts/bootstrap-robot.sh --load-image-tars \
  --phantom-models-tar   /root/phantom-models-2026-06-08.tar \
  --phantom-policies-tar /root/phantom-policies-2026-06-09-sonic-onnx.tar

# Interactive — a full bootstrap on a TTY prompts for each path:
#   phantom-models tarball path?   [Enter to skip]
#   phantom-policies tarball path? [Enter to skip]
sudo bash scripts/bootstrap-robot.sh
```

The interactive prompt only fires on a TTY and when the flag wasn't
given; under `-y`, in selected-phase mode, or with no TTY the phase acts
only on the flags (and is a no-op if neither is set). The phase waits for
the in-cluster registry to be Available first, so the tarballs must
already be on the robot's filesystem (the registry push runs on the robot
— it can't read a file on your workstation). See
[§4](#4-bootstrap-phases-reference) and
[§5](#5-per-phase-invocations-cheat-sheet).

**4. Point the manifests at the loaded tag.** Set the tag in the
`images:` block of `/etc/phantomos/host-config.yaml` and apply it
([§3.2](#32-bump-image-tags)):

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
# images:
#   - phantom-models:2026-06-08
#   - phantom-policies:2026-06-09-sonic-onnx

sudo bash scripts/bootstrap-robot.sh --gitops
```

> **Offline alternative.** With no in-cluster registry reachable you can
> drop the tarballs into `/var/lib/k0s/images/` and run
> `k0s ctr -n k8s.io images import /var/lib/k0s/images/<tar>` so
> containerd has them locally. Caveat: for `localhost:5443/*` refs the
> registry push (step 3) is the durable path — the manifests pull by that
> ref, and a containerd-local import is lost on a `k0s reset` or a node
> that didn't get the import. Use the import only as a stopgap when the
> registry pod is down.

---

### 3.14 CPU isolation and core pinning (EtherCAT RT)

The EtherCAT master runs a hard-real-time cyclic loop. To keep it
jitter-free, bootstrap carves a set of CPU cores out of the kernel's
general scheduling and dedicates them to the RT loop and its NIC. This is
declared in the `cpuIsolation` block of `/etc/phantomos/host-config.yaml`
and applied by phases [9 (ecat-interface)](#4-bootstrap-phases-reference),
[10 (cpu-isolation)](#4-bootstrap-phases-reference), and
[12 (install-dma-ethercat)](#4-bootstrap-phases-reference).

```yaml
cpuIsolation:
  enabled: true
  partitions:
    - name: ecat
      cpus: "11-13"            # the cpuset carved out for EtherCAT
  nic:
    iface: ecat1
    irqCore: 13               # NIC IRQs -> LAST core of the partition
    selector:
      mac: 4c:bb:47:14:14:fc  # OR pci: "0000:01:00.0" OR {driver: igc, index: 0}
  dmaRtCpu: 11                # SOEM cyclic RT loop -> FIRST core of the partition
  installAffinityDefaults: true
```

**Pinning convention.** Within the partition's cpuset, split the RT loop
and IRQ servicing onto opposite ends so they never contend for the same
core:

- **`dmaRtCpu` → the FIRST core of the partition** (`11` for `11-13`).
  This is the SOEM cyclic loop core — the `nohz_full` target, governor
  locked, kthreads/timers steered away. The DMA service runs here
  (`DMA_RT_CPU` in `/etc/dma/dma-ethercat.env`, plus the partition slice
  + `CPUAffinity`).
- **`nic.irqCore` → the LAST core of the partition** (`13` for `11-13`).
  The EtherCAT NIC's hardware IRQs are pinned here via
  `/proc/irq/<n>/smp_affinity`, isolated from the RT loop so interrupt
  handling never steals cycles from the cyclic deadline.
- Cores in between (`12`) are headroom in the isolated partition — free
  for additional RT-adjacent work that should stay off the housekeeping
  CPUs.

So for the default `11-13` partition: **RT loop on 11, IRQs on 13.** Keep
`dmaRtCpu` and `nic.irqCore` inside `partitions[].cpus`, and keep them
distinct (first vs last) — co-locating them reintroduces the IRQ-vs-loop
contention isolation is meant to remove.

**Worked example (mk11000019):** partition `ecat` = `11-13`,
`dmaRtCpu: 11`, `nic.irqCore: 13` — RT loop on the first core, NIC IRQs
on the last.

**Applying changes.** Edit the block, then re-run the isolation phase:

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
sudo bash scripts/bootstrap-robot.sh --cpu-isolation --yes
```

If the kernel cmdline changed (isolcpus / irqaffinity), the phase writes
`/etc/phantomos/cpu-isolation.reboot-pending` — **reboot** to activate.
Verify after reboot:

```bash
cat /sys/devices/system/cpu/isolated          # should list the partition cores
cat /proc/irq/<nic-irq>/smp_affinity_list      # should be nic.irqCore
grep DMA_RT_CPU /etc/dma/dma-ethercat.env      # should be dmaRtCpu
```

---

### 3.15 Manage the dma-ethercat service

The EtherCAT master (`dma_main`) runs as a host systemd service installed
from the `dma-ethercat` `.deb` by [phase 12](#4-bootstrap-phases-reference)
— **not** as a Kubernetes pod. It owns the EtherCAT bus and the
`/dev/shm` DMA variable map that the in-cluster workloads read, so it runs
on the host directly with RT scheduling.

#### Where things live

| What | Path |
|------|------|
| Master binary (the service) | `/usr/bin/dma_main` |
| CLI tools | `/usr/bin/dma_cmd_client`, `dma_motor_motion`, `elmo_query`, `ethercat_error_viewer`, `ethercat_sine_test`, `health_monitor`, `tactile_verify`, … |
| Uninstaller | `/usr/sbin/dma-ethercat-uninstall` |
| systemd unit | `/lib/systemd/system/dma-ethercat.service` |
| Drop-ins (slice, debug, overrides) | `/etc/systemd/system/dma-ethercat.service.d/*.conf` |
| **Runtime config (env)** | `/etc/dma/dma-ethercat.env` (dpkg *conffile* — survives `.deb` upgrades) |
| Shipped hardware configs | `/usr/share/dma-ethercat/config/*.json` (per-robot + variant subdirs) |
| MuJoCo models | `/usr/share/dma-ethercat/config/mujoco/*.xml` |
| cpuset helper scripts | `/usr/lib/dma-ethercat/cpusets/` |

Everything under `/usr/bin`, `/usr/share/dma-ethercat`, and the unit file
is **dpkg-managed** — a `.deb` upgrade overwrites it. Only
`/etc/dma/dma-ethercat.env` and your own drop-ins persist across upgrades.

#### Modifying runtime arguments

The unit's `ExecStart` is:

```
ExecStart=/usr/bin/taskset -c ${DMA_CPU_AFFINITY} /usr/bin/dma_main \
    --config ${DMA_CONFIG} --cpu ${DMA_RT_CPU} --interface ${INTERFACE} \
    --mujoco-model ${DMA_MUJOCO_MODEL} --enable-emcy-monitor --enable-pdo-diagnostics
```

The `${...}` values come from `/etc/dma/dma-ethercat.env`, so most runtime
tuning is just **editing that file and restarting** — no unit edits:

| Argument | env var in `/etc/dma/dma-ethercat.env` |
|----------|----------------------------------------|
| `--config` (hardware JSON) | `DMA_CONFIG` |
| `--interface` (EtherCAT NIC) | `INTERFACE` |
| `--cpu` (RT loop core) | `DMA_RT_CPU` |
| `taskset -c` (CPU affinity) | `DMA_CPU_AFFINITY` |
| `--mujoco-model` | `DMA_MUJOCO_MODEL` |

```bash
sudo $EDITOR /etc/dma/dma-ethercat.env     # e.g. point DMA_CONFIG at a new robot JSON
sudo systemctl restart dma-ethercat
```

To use a custom hardware config, drop the JSON in `/etc/dma/` (not under
`/usr/share`, which dpkg owns) and set `DMA_CONFIG=/etc/dma/my-config.json`.
`DMA_CPU_AFFINITY` / `DMA_RT_CPU` must stay consistent with the
[cpuIsolation](#314-cpu-isolation-and-core-pinning-ethercat-rt) partition
(affinity must be a superset that contains the RT core).

To change the **hardcoded flags** (e.g. drop `--enable-pdo-diagnostics`,
or add a new `dma_main` flag), don't edit the dpkg-owned unit — add a
drop-in that resets and re-declares `ExecStart`:

```bash
sudo systemctl edit dma-ethercat      # writes /etc/systemd/system/dma-ethercat.service.d/override.conf
```
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/taskset -c ${DMA_CPU_AFFINITY} /usr/bin/dma_main \
    --config ${DMA_CONFIG} --cpu ${DMA_RT_CPU} --interface ${INTERFACE} \
    --mujoco-model ${DMA_MUJOCO_MODEL} --enable-emcy-monitor
```

The empty `ExecStart=` is required — systemd appends otherwise. Run
`sudo systemctl daemon-reload && sudo systemctl restart dma-ethercat`
after.

#### systemctl / journalctl cheat sheet

```bash
systemctl status dma-ethercat            # current state, last logs, the active ExecStart
systemctl cat dma-ethercat               # merged unit + every drop-in (verify your override)
sudo systemctl restart dma-ethercat      # apply env / config changes
sudo systemctl stop dma-ethercat         # release the bus (SIGINT; clean stop, ~10s)
sudo systemctl start dma-ethercat
sudo systemctl disable --now dma-ethercat # stop + don't start on boot
sudo systemctl enable  --now dma-ethercat # start + start on boot (bootstrap default)
journalctl -u dma-ethercat -f            # follow logs (SyslogIdentifier=dma-ethercat)
journalctl -u dma-ethercat -b --no-pager # this boot's logs
```

The unit is `Restart=always` (`RestartSec=5`), so a crash auto-restarts —
a climbing restart count in `status` is history, not necessarily an active
fault; check the current **state** and **start time**. `systemctl stop`
sends `SIGINT` for a clean bus shutdown. For deeper failure triage (bus
won't come up, install Job stuck) see
[§7.15](#715-dma-ethercat-installer-job-stuck-or-service-wont-start) and
[§7.16](#716-reading-dma-ethercat-logs).

---

## 4. Bootstrap phases reference

| Phase | Flag | What it does |
|---|---|---|
| 1. preflight | (always) | OS / arch / kernel / disk / sudo / port collisions |
| 2. deps | `--deps` | apt installs; k0s binary **pinned** to a known version (`K0S_VERSION`, default `v1.35.4+k0s.0`) for deterministic bringup — unpinned `get.k0s.sh` installs latest and silently jumped robots to containerd 2.x; terraform binary. Skips k0s install if already present (logs a note if the installed version differs from the pin). |
| 3. cluster | `--cluster` | require Tailscale; pin `spec.api.address` in `/etc/k0s/k0s.yaml`; `k0s install controller --single --enable-worker -c …`; systemd start; write `/root/.kube/config` (server pinned to `127.0.0.1`); reconcile `foundation.bot/*` node labels from `host-config.yaml`'s `nodeLabels:`. Self-heals already-installed clusters that bake the `1.1.1.1` sentinel — see [§3.10](#310-toggle-an-optional-workload-on-a-robot) for the day-2 toggle workflow. |
| 4. host config | `--host` | configure nvidia runtime; restart k0s; wait Ready |
| 5. seed pull secrets | `--seed-pull-secrets` | propagate `dockerhub-creds` Secret to `argus`, `dma-video`, `nimbus`, `phantom` |
| 6. operator-ui-config | `--operator-ui-config` | render+apply `operator-ui-pairing` ConfigMap; roll operator-ui if value changed |
| 7. locomotion-config | `--locomotion-config` | render+apply the `phantom-locomotion-config` ConfigMap from `phantomLocomotion:` (mode/policy/diagnostic); roll the `phantom-locomotion` DaemonSet if present |
| 8. sonic-config | `--sonic-config` | render+apply the `phantom-sonic-config` ConfigMap from `phantomSonic:` (ROS domain, walking policy, encoder mode, ZMQ/web ports, ramp); roll the `phantom-sonic` DaemonSet if present |
| 9. ecat-interface | `--ecat-interface` (default-on; `--skip-ecat-interface` to opt out) | resolve the EtherCAT NIC adapter and rename it to `cpuIsolation.nic.iface` via persistent udev rules. Driven by `cpuIsolation.nic.selector` (mac/pci/driver+index); falls back to the vendored interactive picker on a TTY. **Gates phase 10.** |
| 10. cpu-isolation | `--cpu-isolation` (default-on; `--skip-cpu-isolation` to opt out) | render `/etc/cpusets.conf` from `cpuIsolation.partitions[]`, reconcile orphan partitions, activate cpuset partitions, install `cpusets.service` (boot persistence), render per-partition systemd slice units (`/etc/systemd/system/<name>.slice` with `AllowedCPUs=<cpus>`) so services needing isolated cores can join via `Slice=`, migrate kernel cmdline, write systemd `CPUAffinity` drop-in, pin EtherCAT NIC IRQs. The cmdline migration adds `rcu_nocb_poll`, `skew_tick=1`, `irqaffinity=<housekeeping>`, and `isolcpus=managed_irq,<rt-cpus>` (the only knob excluding isolated CPUs from driver-managed PCIe/MSI-X IRQ allocation). The EtherCAT RT boot service also disables `kernel.timer_migration`, restricts `kernel.watchdog_cpumask` to housekeeping (strictly better than `nosoftlockup`/`nowatchdog` — keeps the safety net), and on Thor / other Tegra hosts best-effort reaffines `nvgpu_*`/`nvhost-*`/`tegra*`/`nv-*` kthreads to housekeeping. **Gates phase 12.** No-op when `cpuIsolation.enabled` is unset/false in `host-config.yaml`. To pick up these behaviors on an existing deployment: `sudo bash scripts/bootstrap-robot.sh --cpu-isolation --yes` and reboot. The cmdline migration sets `/etc/phantomos/cpu-isolation.reboot-pending`. |
| 11. log-management | `--log-management` (default-on; `--skip-log-management` to opt out) | install drop-ins under `/etc/systemd/journald.conf.d/` and `/etc/logrotate.d/` capping journald and rsyslog disk use. Defaults applied when `logManagement:` is absent (opt out via `logManagement.enabled: false`). See [§7.17](#717-recovering-a-robot-with-a-full-varlogsyslog) for full-disk recovery. |
| 12. install-dma-ethercat | `--install-dma-ethercat` | render the installer Job from the host-config tag, apply, dpkg the `.deb`, write `/etc/dma/dma-ethercat.env` (INTERFACE/DMA_RT_CPU/DMA_CPU_AFFINITY from `cpuIsolation`), render the `dma-ethercat.service` drop-in `Slice=<partition>.slice` + `CPUAffinity=` (so the service can actually run on the isolated cores under cgroup-v2), then enable + start. **Gates phase 13.** |
| 13. gitops | `--gitops` | terraform apply (ArgoCD Helm chart); render+apply per-stack Application CRs from `host-config.yaml` |
| 14. argocd admin | `--argocd-admin` | install argocd CLI; reset admin password (default `1984` on empty input) |
| 14b. load-image-tars | `--load-image-tars` (with `--phantom-models-tar <path>` / `--phantom-policies-tar <path>`) | (optional) wait for the `k0s-registry` Deployment to become Available, then load + push the prebuilt `phantom-models` / `phantom-policies` tarballs into `localhost:5443` (via [`scripts/load-image-tars.sh`](../scripts/load-image-tars.sh)) and update the matching `images:` tag in `host-config.yaml`. On an interactive full bootstrap, prompts for any path not given by a flag. Runs **between gitops and image-overrides** so the unchanged image-overrides phase injects the new tag. Soft-skips if neither tarball is provided or the registry never comes up. See [§3.13](#313-copy-a-locally-built-image-to-other-robots-offline-tar-transfer). |
| 15. image overrides | `--image-overrides` | inject `images:` from `host-config.yaml` into the live Applications |
| 16. deployments | `--deployments` | inject `deployments:` patches per stack (or clear when absent). Alias: `--dev-mounts` |

With **no** `--<phase>` flag, every phase runs (full bootstrap).
With **one or more** `--<phase>` flags, only those phases run
(selected-phases mode, implies `-y`).

`--reset` is special: it stops k0s, runs `k0s reset`, backs up
kubeconfig and terraform state, **then exits**. Run bootstrap again
without `--reset` to rebuild.

---

## 5. Per-phase invocations cheat sheet

```bash
# full first bringup
sudo bash scripts/bootstrap-robot.sh

# re-pair AI PC
sudo bash scripts/bootstrap-robot.sh --operator-ui-config

# bump image tags
sudo bash scripts/bootstrap-robot.sh --image-overrides

# load + push prebuilt model/policy tarballs and wire the tag into host-config (see §3.13)
sudo bash scripts/bootstrap-robot.sh --load-image-tars \
  --phantom-models-tar /root/phantom-models-2026-06-08.tar \
  --phantom-policies-tar /root/phantom-policies-2026-06-09-sonic-onnx.tar

# add/remove hostPath mounts
sudo bash scripts/bootstrap-robot.sh --deployments

# toggle stacks / production / branch
sudo bash scripts/bootstrap-robot.sh --gitops

# rotate admin password
sudo bash scripts/bootstrap-robot.sh --argocd-admin

# re-seed dockerhub creds (fixes ImagePullBackOff)
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets

# wipe cluster (preserves /etc/phantomos/, /var/lib/k0s-data/)
sudo bash scripts/bootstrap-robot.sh --reset
sudo bash scripts/bootstrap-robot.sh           # rebuild

# composed: re-pair AI PC AND push image tags in one run
sudo bash scripts/bootstrap-robot.sh --operator-ui-config --image-overrides

# override flags (compose with both modes)
sudo bash scripts/bootstrap-robot.sh --skip-nvidia
sudo bash scripts/bootstrap-robot.sh --gitops --production
sudo bash scripts/bootstrap-robot.sh --gitops --no-production
```

---

## 6. Migration scenarios

### 6.1 Legacy `gitops/apps/<robot>/` umbrella → per-stack Applications

Older robots ran an app-of-apps: a `root` Application read
`gitops/apps/<robot>/` and created a single per-robot child
(`phantomos-<robot>`). The current model creates one Application
per stack (`phantomos-<robot>-core`, `phantomos-<robot>-operator`)
directly from `host-config.yaml`, with no umbrella.

Migration is automatic on the next `--gitops` (or full bootstrap):

1. Ensure `host-config.yaml` exists and lists the stacks you want.
2. Run `sudo bash scripts/bootstrap-robot.sh --gitops`.
3. Bootstrap detects the legacy umbrella `Application` and the
   `root` parent, strips them **without cascading prune** (existing
   pods keep running), and creates the new per-stack Applications.
4. Once Synced + Healthy, ArgoCD takes ownership. No workload
   downtime.

To verify the umbrella is gone:

```bash
sudo k0s kubectl -n argocd get app | grep -v "<robot>-core\|<robot>-operator"
# should show no phantomos-<robot> umbrella
```

### 6.2 Legacy `devMode:` block → `deployments:` schema

Older `host-config.yaml` files carried a `devMode:` stanza:

```yaml
devMode:
  positronic-control:
    source: /home/yourname/development/foundation/positronic_control
    mounts:
      - {host: /data, container: /data}
    privileged: true
```

The wizard reads `devMode:` if present and re-emits it as the
current `deployments:` schema:

```yaml
deployments:
  positronic-control:
    privileged: true
    mounts:
      - {name: src,  host: /home/yourname/development/foundation/positronic_control, container: /src}
      - {name: data, host: /data, container: /data}
```

Migration:

```bash
sudo bash scripts/configure-host.sh    # reads devMode:, writes deployments:
sudo bash scripts/bootstrap-robot.sh --deployments
```

The single `source:` path is mounted at `/src` (the wizard adds the
`name: src` entry). All other entries copy across verbatim.

### 6.3 Production robot picking up Stage F base cleanup

Stage F shrinks the base manifests to only universal kernel/runtime
mounts (`/dev`, `/dev/shm`, `/tmp`). Every other path
(`/data`, `/data2`, `/root/recordings`, `/data/torch`) now lives in
`host-config.yaml` under `deployments.positronic-control.mounts`.

Existing production robots will roll the pod with **fewer
hostPaths** when they next sync — paths the robot still needs must
be re-declared in host-config.yaml.

Recipe:

1. Edit `/etc/phantomos/host-config.yaml`:

   ```yaml
   deployments:
     positronic-control:
       privileged: false
       mounts:
         - {name: data,        host: /data,            container: /data}
         - {name: data2,       host: /data2,           container: /data2}
         - {name: recordings,  host: /root/recordings, container: /recordings}
         - {name: torch-hub,   host: /data/torch,      container: /root/.cache/torch/hub}
   ```

2. Apply:

   ```bash
   sudo bash scripts/bootstrap-robot.sh --deployments
   ```

3. Verify the pod has the mounts:

   ```bash
   sudo k0s kubectl -n positronic exec deploy/positronic-control -- ls /data /data2 /recordings
   ```

Skip steps 1-2 only if you want the bare-base behaviour (no host
data mounted into positronic-control).

### 6.4 Legacy `manifests/installers/dma-ethercat/robots/<name>/` → `host-config.yaml:images`

Older bringups carried a per-robot kustomization under
`manifests/installers/dma-ethercat/robots/<robot>/kustomization.yaml`
that pinned the `foundationbot/dma-ethercat` image tag for the
installer Job. Our branch templatizes that tree away: a single
template at `manifests/installers/dma-ethercat/base/job.yaml` carries
`:PLACEHOLDER`, and the real tag flows in via `host-config.yaml:images`.

Migration:

1. Read the tag from the (now-deleted) per-robot file on a sibling
   robot or from team records, e.g. `main-latest-aarch64`.

2. Add it to `/etc/phantomos/host-config.yaml`:

   ```yaml
   images:
     - name: foundationbot/dma-ethercat
       newTag: main-latest-aarch64
   ```

3. Apply:

   ```bash
   sudo bash scripts/bootstrap-robot.sh --install-dma-ethercat
   ```

The base template renders once and reuses across the fleet — adding a
new robot needs no installer-tree commit, just a host-config entry.

---

## 7. Troubleshooting

### Decision tree: what command do I need?

```
                       symptom
                          |
       +------------------+------------------+
       |                  |                  |
   pod won't         Application         can't login
   start                drift            to ArgoCD
       |                  |                  |
       v                  v                  v
   ImagePullBackOff   OutOfSync         --argocd-admin
   /CrashLoop         /Unknown
       |                  |
       v                  v
  see 7.1 / 7.2      see 7.3 / 7.6
```

### 7.1 `Init:ImagePullBackOff` on positronic-control

Image overrides didn't apply, the requested tag doesn't exist on
DockerHub, or the `dockerhub-creds` pull secret is missing in the
`positronic` namespace. positronic-control, phantom-models, and
phantom-policies all pull from `foundationbot/*` on DockerHub like
every other private image.

```bash
# Check what tag the live Application is trying to pull
sudo k0s kubectl -n argocd get app phantomos-<robot>-core \
  -o jsonpath='{.spec.source.kustomize.images}' ; echo

# Confirm the pull secret is present in the namespace
sudo k0s kubectl -n positronic get secret dockerhub-creds
# missing? re-seed it:
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets

# If the override is missing, re-run the phase
sudo bash scripts/bootstrap-robot.sh --image-overrides
```

If the credentials and tag are both good but the pod still won't pull,
kick the pod to retry:

```bash
sudo k0s kubectl -n positronic delete pod -l app=positronic-control
```

See [§7.13](#713-pods-imagepullbackoff-for-foundationbot-images) for the
full DockerHub pull-secret recovery path.

### 7.2 Image shows `:PLACEHOLDER`

The base manifest's image is literal `foundationbot/<name>:PLACEHOLDER`.
Either `host-config.yaml` doesn't list that image under `images:` or
`--image-overrides` hasn't run since the last edit.

```bash
sudo bash scripts/configure-host.sh --show
sudo bash scripts/bootstrap-robot.sh --image-overrides
```

### 7.3 `phantomos-<robot>-core` stuck `OutOfSync`

Force a sync:

```bash
sudo k0s kubectl -n argocd patch app phantomos-<robot>-core \
  --type merge -p '{"operation":{"sync":{}}}'

# or hard refresh
sudo k0s kubectl -n argocd annotate app phantomos-<robot>-core \
  argocd.argoproj.io/refresh=hard --overwrite
```

If the sync fails with a manifest error, run
`bootstrap-robot.sh --gitops` to re-render the Application from
the current `host-config.yaml`.

### 7.4 Pod CrashLooping on missing hostPath

A `deployments:` mount references a path that doesn't exist on the
host. Either create the directory:

```bash
sudo mkdir -p /data /data2 /root/recordings /data/torch
```

...or remove the mount from `host-config.yaml`:

```bash
sudo $EDITOR /etc/phantomos/host-config.yaml
sudo bash scripts/bootstrap-robot.sh --deployments
```

### 7.5 `argocd login` fails

Reset the admin password:

```bash
sudo bash scripts/bootstrap-robot.sh --argocd-admin
# enter on the prompt for the default '1984', or type a new value
```

If the CLI itself is missing, the same phase reinstalls it under
`/usr/local/bin/argocd`.

### 7.6 Stack disabled but workloads still running

`--gitops` is what removes Applications. If you flipped
`stacks.operator.enabled: false` but didn't re-render:

```bash
sudo bash scripts/bootstrap-robot.sh --gitops
```

The phase deletes the disabled Application; ArgoCD's cascade prune
then deletes the namespaces and workloads. If pods linger after the
Application is gone, delete the namespace by hand:

```bash
sudo k0s kubectl delete namespace argus nimbus
```

### 7.7 `error: could not determine robot identity`

First bringup with no `/etc/phantomos/robot` and no `--robot` flag.

```bash
sudo bash scripts/configure-host.sh    # writes host-config.yaml + robot id
# or pass --robot explicitly:
sudo bash scripts/bootstrap-robot.sh --robot <name>
```

Once persisted to `/etc/phantomos/robot`, subsequent runs read it
automatically.

### 7.8 Wizard rejects robot name

DNS-1123: lowercase alphanumeric + hyphens, 1..63 chars, bookended
by alphanumeric. `mk_09` is invalid. `MK09` is normalized to
`mk09`. `-mk09` and `mk09-` are invalid.

### 7.9 Corrupted `host-config.yaml`

Restore from a working sibling:

```bash
ssh <other-robot> "sudo cat /etc/phantomos/host-config.yaml" \
  | sudo tee /etc/phantomos/host-config.yaml
sudo bash scripts/configure-host.sh --validate
```

Or re-seed from an operator-supplied template tree:

```bash
sudo bash scripts/configure-host.sh --from-template ~/phantom-fleet-config/<robot>
```

Or start from the schema:

```bash
sudo cp host-config-templates/_template/host-config.yaml \
        /etc/phantomos/host-config.yaml
sudo bash scripts/configure-host.sh
```

### 7.10 Cluster wipe and rebuild

```bash
sudo bash scripts/bootstrap-robot.sh --reset    # purges and exits
sudo bash scripts/bootstrap-robot.sh            # rebuild
```

`--reset` runs `k0s stop && k0s reset` and backs up
`/root/.kube/config` and `terraform/terraform.tfstate*` to
`.bak.<timestamp>`. Preserved across the wipe:

- `/etc/phantomos/` (host-config, robot id, pairing, app manifest)
- `/var/lib/k0s-data/` (database hostPaths: mongodb, redis, postgres)

Cluster workload state and the kubeconfig are destroyed. After the
rebuild, expect to re-seed dockerhub creds (`--seed-pull-secrets`)
and confirm node labels for any DaemonSets.

### 7.11 `k0scontroller` won't start

```bash
sudo journalctl -u k0scontroller -n 200 --no-pager
```

Most often a previous k0s install left residue. Cleanest recovery:

```bash
sudo bash scripts/bootstrap-robot.sh --reset
sudo bash scripts/bootstrap-robot.sh
```

### 7.12 Operator UI shows wrong AI PC URL

The ConfigMap is stale or operator-ui hasn't rolled.

```bash
sudo k0s kubectl -n argus exec deploy/operator-ui -- env | grep AI_PC_URL
```

If wrong, re-render and roll:

```bash
sudo bash scripts/bootstrap-robot.sh --operator-ui-config
# or force a roll only
sudo k0s kubectl -n argus rollout restart deploy/operator-ui
```

### 7.13 Pods `ImagePullBackOff` for `foundationbot/*` images

Pull credentials missing in the namespace.

```bash
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets
```

If `~/.docker/config.json` is absent or credsStore-only, pass an
explicit credentials file:

```bash
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets \
  --dockerhub-secret-file /path/to/dockerconfig.json
```

For credstore-detection, fresh-pull recipes, and the PAT rotation
loop, see [`dockerhub-creds.md`](./dockerhub-creds.md).

### 7.14 NVIDIA pod missing GPU

```bash
sudo k0s kubectl get runtimeclass nvidia
sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{.items[0].spec.runtimeClassName}{"\n"}'   # expect: nvidia
```

If the RuntimeClass is missing, re-run the host phase:

```bash
sudo bash scripts/bootstrap-robot.sh --host
```

To force-skip nvidia config (CPU-only host):

```bash
sudo bash scripts/bootstrap-robot.sh --host --skip-nvidia
```

### 7.15 dma-ethercat installer Job stuck or service won't start

Phase 12 (`--install-dma-ethercat`) gates phase 13 (gitops): a failure
halts the bootstrap with a `DMA-ETHERCAT FAILURE` banner. Diagnose by
sub-step.

Image tag missing from host-config:

```bash
grep -A1 'foundationbot/dma-ethercat' /etc/phantomos/host-config.yaml \
  || echo "no entry — add one and re-run"
```

Job never reached `Complete`:

```bash
sudo k0s kubectl -n phantom describe job dma-ethercat-installer
sudo k0s kubectl -n phantom logs -l app=dma-ethercat-installer --tail=100
```

Most common: image pull failure. The Job pulls a private image —
confirm `dockerhub-creds` is in the `phantom` namespace:

```bash
sudo k0s kubectl -n phantom get secret dockerhub-creds
# missing? re-seed:
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets
sudo bash scripts/bootstrap-robot.sh --install-dma-ethercat
```

Job complete but no `.deb` on host:

```bash
ls -la /var/lib/dma-ethercat-installer/
# expect dma-ethercat-*.deb + .ready sentinel
```

If only `.ready` is present, the image's `/usr/local/share/dma/deb/`
path was empty — usually a wrong-arch tag (an `-amd64` tag on an
aarch64 host, or vice versa). Fix the tag in `host-config.yaml:images`
and re-run.

`dpkg -i` failed: read the dpkg output (the bootstrap streams it).
Usually a missing runtime dependency. Install the dependency and
re-run the phase.

`systemctl enable --now dma-ethercat.service` failed:

```bash
sudo systemctl status dma-ethercat.service
sudo journalctl -u dma-ethercat -b --no-pager
```

Most common: wrong `INTERFACE` in `/etc/dma/dma-ethercat.env`, or the
RT cores in `DMA_CPU_AFFINITY` aren't isolated.

To bypass the gate while debugging (e.g. operator already has the
`.deb` installed by hand):

```bash
sudo bash scripts/bootstrap-robot.sh --skip-ethercat-install
```

### 7.16 Reading dma-ethercat logs

The DMA service runs on the host (not in k0s), so its logs are in
journald — **not** `kubectl logs`:

```bash
sudo journalctl -u dma-ethercat -f
sudo journalctl -u dma-ethercat -b --no-pager   # this boot
```

### 7.17 Recovering a robot with a full `/var/log/syslog`

Symptom: `df -h /` reports the root partition at 100%, and
`du -sh /var/log/*` shows `/var/log/syslog` (or `syslog.1`) at
hundreds of GB.

Cause on robots bootstrapped before the `log-management` phase landed:
the stock `/etc/logrotate.d/rsyslog` ships with `weekly` rotation and
no `maxsize`, so `/var/log/syslog` grows unbounded between weekly
rotations. A bursty service (e.g. a tight crash loop) can fill a
near-empty disk in hours.

Recovery (run as root):

```bash
# 1. Stop rsyslog so the file isn't being written while you truncate.
systemctl stop rsyslog

# 2. Truncate in place. (Don't `rm` — it leaves the inode held by
#    rsyslog's open fd until next restart, so disk space isn't freed.)
truncate -s 0 /var/log/syslog

# 3. Drop large rotated copies.
rm -f /var/log/syslog.[1-9]*

# 4. Bring rsyslog back.
systemctl start rsyslog

# 5. Install caps so this can't recur.
cd /opt/Phantom-OS-KubernetesOptions
sudo bash scripts/bootstrap-robot.sh --log-management -y

# 6. Verify caps in place.
cat /etc/logrotate.d/phantomos-syslog
cat /etc/systemd/journald.conf.d/phantomos.conf
```

The `--log-management` phase is idempotent — re-running it on a
configured host leaves the drop-ins unchanged and does not restart
journald.

To customise the caps per host, add a `logManagement:` block to
`/etc/phantomos/host-config.yaml` and re-run the phase. See the
template at `host-config-templates/_template/host-config.yaml` for
the full schema and defaults.

### 7.18 `phantom-sonic` walking/sonic CrashLoop on `shm_open`

**Symptom:** the `phantom-sonic` pod is `Running` but the `walking`
and/or `sonic` containers restart-loop. Their logs end with:

```
dma_common.errors.DmaIpcNotAttachedError: failed to attach to IPC
queue '/actuals': shm_open failed (reader): No such file or directory
```

`control` and `motion-replay` stay up (they don't attach to `/actuals`
at boot), so the pod still shows e.g. `4/4` between restarts.

**Cause:** the policy nodes read DMA.ethercat's shared-memory queues
under `/dev/shm`. Those queues don't exist because **DMA.ethercat isn't
running** — the bare-metal `dma-ethercat.service` is the producer, not a
pod.

```bash
# Confirm the producer is down and the queues are absent:
systemctl is-active dma-ethercat            # expect: inactive
ls /dev/shm/                                # expect: no actuals/desired/config
```

**Fix:** start DMA.ethercat, then let the containers recover (they're
already restarting, so they reattach within ~30s — or force it):

```bash
sudo systemctl start dma-ethercat
ls /dev/shm/                                # now shows actuals, desired, config, ...
kubectl -n positronic delete pod -l app.kubernetes.io/name=phantom-sonic
```

> ⚠️ Starting `dma-ethercat` engages the EtherCAT master to the real
> actuators. The robot boots **idle** (no `/desired` writes until you
> press X on the joystick), but keep the e-stop in reach.

If `dma-ethercat` itself won't start, see
[§7.15](#715-dma-ethercat-installer-job-stuck-or-service-wont-start).
Note the `restartCount` on `walking`/`sonic` stays elevated after
recovery — that's the historical count, not ongoing failure; check the
container's current **state** (`Running`) and **start time**, not the
counter. The same missing-`/dev/shm` cause also CrashLoops `dma-bridge`.

---

### 7.20 `k0scontroller` crash-loops: `unsupported configuration version: expected 3, got 2`

**Symptom.** Cluster bringup "hangs" — `k0s kubectl` reports
`connection to the server localhost:6443 was refused`, and
`systemctl status k0scontroller` shows `activating` with a high restart
counter. `journalctl -u k0scontroller` repeats:

```
Rejected: unsupported configuration version: expected 3, got 2
  configuration contains a [plugins."io.containerd.grpc.v1.cri"] section
  which is the containerd v1 CRI plugin format
  pre-flight-check="containerd:configSnippets/file:10-registry-mirror.toml"
```

**Cause.** k0s **≥ 1.36** bundles **containerd 2.x**, whose config is
`version = 3` with the split CRI plugins (`io.containerd.cri.v1.images`,
`io.containerd.cri.v1.runtime`). The containerd drop-ins under
`/etc/k0s/containerd.d/` were written in the old containerd-1.7.x format
(`version = 2`, `io.containerd.grpc.v1.cri`) and k0s rejects them at
pre-flight, so the controller never starts. This bites robots that
installed k0s **before** the version pin landed (bootstrap now pins k0s —
see [§4 phase 2](#4-bootstrap-phases-reference) — and the configure
scripts now emit the format matching the bundled containerd).

**Fix.** Re-run the host-config phase so the drop-ins are regenerated in
the correct format, then restart:

```bash
sudo bash scripts/configure-k0s-containerd-mirror.sh
sudo bash scripts/configure-k0s-nvidia-runtime.sh   # if the robot uses GPU
sudo systemctl restart k0scontroller
# watch it settle:
sudo systemctl is-active k0scontroller        # -> active
sudo k0s kubectl get nodes                     # -> Ready
```

Or convert the two files by hand: set `version = 3`, rename
`[plugins."io.containerd.grpc.v1.cri".registry]` →
`[plugins."io.containerd.cri.v1.images".registry]` and
`[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]` →
`[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]`
(and its `.options` table), then restart k0s.

---

### 7.21 dma-video pods `Pending` — `/etc/phantom/head_camera.json` missing

**Symptom.** `camera-params`, `producer`, and/or `rtsp-streamer` in the
`dma-video` namespace stay `Pending`/`ContainerCreating`; a `describe`
shows:

```
MountVolume.SetUp failed for volume "cameras-config" ...
hostPath type check failed: /etc/phantom/head_camera.json is not a file
```

**Cause.** Those pods mount the **per-host** OAK camera config from
`/etc/phantom/head_camera.json` via `hostPath` with `type: File`, so a
missing (or directory-shaped) path makes the kubelet refuse to start the
pod — deliberate loud failure, no silent fleet default. ArgoCD does
**not** create or reconcile this file (it's per-robot hardware config).

**Fix — create `/etc/phantom/head_camera.json` from the robot's OAK
module ID (MXID).** Each OAK camera has a unique MXID (Luxonis device
serial / "module ID"); the file maps boards (by MXID) to camera sockets
+ intrinsics. Discover the attached OAK's MXID with DepthAI:

```bash
python3 -c 'import depthai; print([d.getMxId() for d in depthai.Device.getAllAvailableDevices()])'
# e.g. ['19443010819F4F2E00']
```

Then write the file (the head has three cameras — see the layout note
below; add intrinsics per camera from calibration, omitted here for
brevity):

```json
{
  "boards": { "0": { "mxid": "19443010819F4F2E00" } },
  "cameras": {
    "bottom": { "queue_id": 0, "board": 0, "socket": "B", "type": "color", "resolution": [1280, 800], "intrinsics": { "matrix": [...], "distortion": [...] } },
    "left":   { "queue_id": 1, "board": 0, "socket": "C", "type": "mono",  "resolution": [1280, 800], "intrinsics": { "matrix": [...], "distortion": [...] } },
    "right":  { "queue_id": 2, "board": 0, "socket": "A", "type": "mono",  "resolution": [1280, 800], "intrinsics": { "matrix": [...], "distortion": [...] } }
  }
}
```

```bash
sudo install -D -m 0644 head_camera.json /etc/phantom/head_camera.json
# the dma-video pods schedule on the next reconcile (or: kubectl -n dma-video rollout restart deploy)
```

**Get these right when authoring/editing the file:**
- **Camera module ID (MXID)** — `boards.<n>.mxid` must match the actual
  OAK on this robot (from the DepthAI probe above). A wrong MXID means
  the producer can't open the device.
- **Each port's position and type** — the head has three cameras and
  every entry must map to the correct physical position and sensor type:
  **`bottom` (cam0) is COLOR; `left` and `right` are MONO**. Mixing up
  positions or marking a mono camera as color (or vice-versa) yields
  garbled/empty streams even though the pods come up.
- **`socket`** — the `A`/`B`/`C` value is the OAK-D's physical port the
  camera is plugged into; it must match your unit's wiring. The letters
  in the example above are illustrative — verify against the actual board
  (only `bottom: "B"` is confirmed from an in-fleet config).

> **Use the OAK-D proprietary USB cable.** Third-party USB cables are
> unreliable for the OAK-D's data rate — they cause intermittent
> DepthAI disconnects / firmware-boot failures that look like camera
> faults. Use the cable that ships with the OAK-D module.

The OAK USB-power udev rule that keeps the device from dropping during
DepthAI firmware boot is installed by bootstrap automatically
([scripts/configure-usb-power.sh](../scripts/configure-usb-power.sh)) —
no action needed there. On a host with **no** OAK hardware, leave
`foundation.bot/has-cameras: 'false'` in `host-config.yaml`'s
`nodeLabels:` so the dma-video stack isn't scheduled at all.

---

## 8. Reference

### 8.1 Filesystem map

| Path | What it is |
|---|---|
| `/etc/phantomos/host-config.yaml` | Per-host source-of-truth. The thing you edit. |
| `/etc/phantomos/robot` | One-line robot id. Auto-written by bootstrap. |
| `/etc/phantomos/operator-ui-pairing.yaml` | ConfigMap derived from `aiPcUrl`. Auto-written. |
| `/etc/phantomos/phantomos-app-<stack>.yaml` | Rendered Application CR (one per enabled stack). Auto-written. |
| `/var/lib/k0s-data/` | Database hostPath volumes. Survives `--reset`. |
| `/var/lib/recordings/` | On-host recording storage. Survives `--reset`. |
| `host-config-templates/_template/host-config.yaml` | Generic schema template. |
| `host-config-templates/_template/phantomos-app.yaml.tpl` | Application CR template. |
| `manifests/stacks/core/` | Core stack kustomize root. |
| `manifests/stacks/operator/` | Operator stack kustomize root (argus + nimbus). |
| `scripts/configure-host.sh` | Wizard for `host-config.yaml`. |
| `scripts/bootstrap-robot.sh` | Cluster bringup + apply config. |
| `scripts/positronic.sh` | Day-2 helper for positronic-control. |
| `terraform/` | Terraform module that installs ArgoCD via Helm. |

### 8.2 Command reference

| Goal | Command |
|---|---|
| First bringup | `sudo bash scripts/bootstrap-robot.sh` |
| Edit host-config | `sudo bash scripts/configure-host.sh` |
| Show current host-config | `sudo bash scripts/configure-host.sh --show` |
| Validate host-config | `sudo bash scripts/configure-host.sh --validate` |
| Pre-fill from external template | `sudo bash scripts/configure-host.sh --from-template <path>` |
| Re-pair AI PC | `sudo bash scripts/bootstrap-robot.sh --operator-ui-config` |
| Bump image tags | `sudo bash scripts/bootstrap-robot.sh --image-overrides` |
| Add/remove mounts | `sudo bash scripts/bootstrap-robot.sh --deployments` |
| Toggle stack / production / branch | `sudo bash scripts/bootstrap-robot.sh --gitops` |
| Rotate ArgoCD password | `sudo bash scripts/bootstrap-robot.sh --argocd-admin` |
| Re-seed dockerhub creds | `sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets` |
| Wipe cluster | `sudo bash scripts/bootstrap-robot.sh --reset` |
| Pod state / logs / exec | `bash scripts/positronic.sh status\|logs\|exec` |
| phantom-sonic state / logs / exec | `bash scripts/positronic.sh sonic status\|logs\|exec\|restart\|web` |
| Force-sync an Application | `sudo k0s kubectl -n argocd patch app phantomos-<robot>-core --type merge -p '{"operation":{"sync":{}}}'` |
| ArgoCD UI port-forward | `sudo k0s kubectl -n argocd port-forward svc/argocd-server 8080:443` |
| Operator UI | `http://<robot-ip>:30080` |

### 8.3 Host ports exposed by stack workloads

Ports bound on the robot's host network namespace by each stack. Use
this when diagnosing port collisions, opening firewall holes, or
mapping a tcpdump back to the workload that owns the socket.

**Core stack** — explicit `hostPort` declarations:

| Port | Proto | Owner | Bind | Source |
|---|---|---|---|---|
| 5000 | TCP | `phantomos-api-server` | all | `manifests/base/phantomos-api-server/phantomos-api-server.yaml` |
| 8008 | TCP | `yovariable-server` (variable) | all | `manifests/base/yovariable-server/yovariable-server.yaml` |
| 8080 | TCP | `yovariable-server` (admin) | all | `manifests/base/yovariable-server/yovariable-server.yaml` |
| 9788 | TCP | `rerun-streamer` | all | `manifests/base/dma-streams/rerun-streamer.yaml` |
| 7400 | UDP | `phantom-locomotion` (ROS 2 / DDS) | all | `manifests/base/phantom-locomotion/phantom-locomotion.yaml` |

**Core stack** — `hostNetwork: true` pods (ports bound by the process
land directly on the host):

| Port(s) | Proto | Owner | Source |
|---|---|---|---|
| 8554 | TCP | `mediamtx` RTSP | `manifests/base/dma-video/configmaps.yaml` |
| 8888 | TCP | `mediamtx` HLS | `manifests/base/dma-video/configmaps.yaml` |
| 8889 | TCP | `mediamtx` WebRTC | `manifests/base/dma-video/configmaps.yaml` |
| 9997 | TCP | `mediamtx` API | `manifests/base/dma-video/mediamtx.yaml` (`MTX_APIADDRESS`) |
| 9299 | TCP | `viewer` (`--port 9299`) | `manifests/base/dma-video/viewer.yaml` |
| 8420 | TCP | `camera-params` (`--port 8420`) | `manifests/base/dma-video/camera-params.yaml` |
| 7865 | TCP | `phantom-sonic` / `motion-replay` web UI (`WEB_PORT`) | `manifests/base/phantom-sonic/phantom-sonic.yaml` |
| 5557 | TCP | `phantom-sonic` motion ZMQ stream (`MOTION_ZMQ_PORT`) | `manifests/base/phantom-sonic/phantom-sonic.yaml` |
| 5558 | TCP | `phantom-sonic` mode-control ZMQ (`CONTROL_ZMQ_PORT`) | `manifests/base/phantom-sonic/phantom-sonic.yaml` |
| 8090 | TCP | `wolverine-loco` teleop web UI (`--port 8090`) | `manifests/base/wolverine-loco/wolverine-loco.yaml` |
| dynamic 7400+ | UDP | `positronic-control`, `phantom-sonic`, `cpp-robot-state-estimator` ROS 2 / DDS | respective deployment YAMLs |

`producer` and `rtsp-streamer` use `hostNetwork: true` for USB / IPC
access but only publish outbound to `mediamtx`; neither opens a
listening port. `dma-recorder` runs with `hostNetwork: false`.

**Operator stack** — host-exposed:

| Port | Proto | Owner | Source |
|---|---|---|---|
| 30080 | TCP | `nginx` → `operator-ui` (NodePort, every node IP) | `manifests/base/argus/nginx.yaml` |

**Operator stack** — cluster-internal `ClusterIP` Services (reachable
only from inside the cluster, e.g. `argus-auth.argus.svc.cluster.local:9000`;
not bound on the host):

| Service.port | Pod containerPort | Owner | Source |
|---|---|---|---|
| 80 | 80 | `nginx` (front-door, fronted by the 30080 NodePort) | `manifests/base/argus/nginx.yaml` |
| 8004 | 8004 | `operator-ui` | `manifests/base/argus/operator-ui.yaml` |
| 9000 | 9000 | `argus-auth` | `manifests/base/argus/argus-auth.yaml` |
| 9001 | 9001 | `argus-user` | `manifests/base/argus/argus-user.yaml` |
| 9002 | 9002 | `argus-company` | `manifests/base/argus/argus-company.yaml` |
| 9100 | 9100 | `argus-gateway` | `manifests/base/argus/argus-gateway.yaml` |
| 27017 | 27017 | `mongodb` | `manifests/base/argus/mongodb.yaml` |
| 6379 | 6379 | `redis` | `manifests/base/argus/redis.yaml` |
| 8080 | 80 | `eg-server` (nimbus) | `manifests/base/nimbus/eg-server.yaml` |
| 5432 | 5432 | `postgres` (nimbus) | `manifests/base/nimbus/postgres.yaml` |

### 8.4 Targeted overrides

| Flag | Effect |
|---|---|
| `--skip-nvidia` | Skip nvidia runtime config in the host phase |
| `--production` | Force `selfHeal: true` for this run |
| `--no-production` | Force `selfHeal: false` for this run |
| `--keep-going` | Continue after FAIL (default: bail) |
| `--dry-run` | Print plan, change nothing |
| `-y, --yes` | Skip confirmation prompts |

For deeper sub-system debugging see [architecture.md](./architecture.md).
