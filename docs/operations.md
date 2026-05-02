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
mode). `--skip-nvidia`, `--skip-validate` are targeted overrides that
compose with both selected-phases and full-bootstrap modes.

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
  localhost:5443/positronic-control tag [0.2.44-production-cu130]:
  localhost:5443/phantom-models tag [2026-04-30]:
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
# the image override didn't apply or the registry doesn't have the tag.
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

The bare-metal `dma-ethercat` service is installed by phase 5.7 from a
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

---

## 4. Bootstrap phases reference

| Phase | Flag | What it does |
|---|---|---|
| 1. preflight | (always) | OS / arch / kernel / disk / sudo / port collisions |
| 2. deps | `--deps` | apt installs, k0s binary, terraform binary |
| 3. cluster | `--cluster` | `k0s install controller --single --enable-worker`; systemd start; write `/root/.kube/config` |
| 4. host config | `--host` | configure containerd mirror + nvidia runtime; restart k0s; wait Ready |
| 5. seed pull secrets | `--seed-pull-secrets` | propagate `dockerhub-creds` Secret to `argus`, `dma-video`, `nimbus`, `phantom` |
| 5.5 operator-ui-config | `--operator-ui-config` | render+apply `operator-ui-pairing` ConfigMap; roll operator-ui if value changed |
| 5.7 install-dma-ethercat | `--install-dma-ethercat` | render the installer Job from the host-config tag, apply, dpkg the .deb, enable + start `dma-ethercat.service`. **Gates phase 6.** |
| 6. gitops | `--gitops` | terraform apply (ArgoCD Helm chart); render+apply per-stack Application CRs from `host-config.yaml` |
| 6.5 argocd admin | `--argocd-admin` | install argocd CLI; reset admin password (default `1984` on empty input) |
| 6.7 image overrides | `--image-overrides` | inject `images:` from `host-config.yaml` into the live Applications |
| 6.8 deployments | `--deployments` | inject `deployments:` patches per stack (or clear when absent). Alias: `--dev-mounts` |
| 7. setup-positronic | `--setup-positronic` | (optional) push positronic-control image, build phantom-models, redeploy |
| 8. validate | `--validate` | `scripts/validate-local-registry.sh` |

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

# add/remove hostPath mounts
sudo bash scripts/bootstrap-robot.sh --deployments

# toggle stacks / production / branch
sudo bash scripts/bootstrap-robot.sh --gitops

# rotate admin password
sudo bash scripts/bootstrap-robot.sh --argocd-admin

# re-seed dockerhub creds (fixes ImagePullBackOff)
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets

# re-validate the registry
sudo bash scripts/bootstrap-robot.sh --validate

# wipe cluster (preserves /etc/phantomos/, /var/lib/k0s-data/, /var/lib/registry/)
sudo bash scripts/bootstrap-robot.sh --reset
sudo bash scripts/bootstrap-robot.sh           # rebuild

# composed: re-pair AI PC AND push image tags in one run
sudo bash scripts/bootstrap-robot.sh --operator-ui-config --image-overrides

# override flags (compose with both modes)
sudo bash scripts/bootstrap-robot.sh --skip-nvidia --skip-validate
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

Image overrides didn't apply, or the requested tag doesn't exist in
the local registry.

```bash
# Check what tag the live Application is trying to pull
sudo k0s kubectl -n argocd get app phantomos-<robot>-core \
  -o jsonpath='{.spec.source.kustomize.images}' ; echo

# Check what's actually in the registry
curl -fs http://localhost:5443/v2/positronic-control/tags/list

# If the override is missing, re-run the phase
sudo bash scripts/bootstrap-robot.sh --image-overrides
```

If the registry has the tag but the pod still won't pull, kick the
pod to retry:

```bash
sudo k0s kubectl -n positronic delete pod -l app=positronic-control
```

### 7.2 Image shows `:PLACEHOLDER`

The base manifest's image is literal `localhost:5443/<name>:PLACEHOLDER`.
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
- `/var/lib/registry/` (local Docker registry blobs)

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

Phase 5.7 (`--install-dma-ethercat`) gates phase 6 (gitops): a failure
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

### 7.17 Validate-registry failures

```bash
sudo bash scripts/validate-local-registry.sh
# exit code = number of failed checks; output names each one
```

To skip the validation step during bootstrap on a known-good host:

```bash
sudo bash scripts/bootstrap-robot.sh --skip-validate
```

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
| `/var/lib/registry/` | Local Docker registry blobs. Survives `--reset`. |
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
| Validate registry | `sudo bash scripts/validate-local-registry.sh` |
| Pod state / logs / exec | `bash scripts/positronic.sh status\|logs\|exec` |
| Force-sync an Application | `sudo k0s kubectl -n argocd patch app phantomos-<robot>-core --type merge -p '{"operation":{"sync":{}}}'` |
| ArgoCD UI port-forward | `sudo k0s kubectl -n argocd port-forward svc/argocd-server 8080:443` |
| Operator UI | `http://<robot-ip>:30080` |

### 8.3 Targeted overrides

| Flag | Effect |
|---|---|
| `--skip-nvidia` | Skip nvidia runtime config in the host phase |
| `--skip-validate` | Skip the final validate-local-registry pass |
| `--production` | Force `selfHeal: true` for this run |
| `--no-production` | Force `selfHeal: false` for this run |
| `--keep-going` | Continue after FAIL (default: bail) |
| `--dry-run` | Print plan, change nothing |
| `-y, --yes` | Skip confirmation prompts |

For deeper sub-system debugging see [architecture.md](./architecture.md).
