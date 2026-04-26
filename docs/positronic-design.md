# positronic-control on k0s — design

How the positronic-control deployment fits together: the two repos, the
three images, the storage layers, the pod composition, the per-robot
overlay model, and the ArgoCD wiring. For day-to-day commands see
[positronic-cheatsheet.md](positronic-cheatsheet.md). For the original
design intent + decision history see
[../docs/plans/2026-04-24-positronic-k0s-migration.md](plans/2026-04-24-positronic-k0s-migration.md)
and
[../docs/plans/2026-04-24-local-registry-with-fallback.md](plans/2026-04-24-local-registry-with-fallback.md).

---

## 1. High level

```
┌──────────────────────────────────────────────────────────────────┐
│ robot (mk09)                                                     │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────────────┐    │
│  │ k0s-registry pod     │    │ positronic-control pod       │    │
│  │ namespace: registry  │    │ namespace: positronic        │    │
│  │ host:127.0.0.1:5443  │    │ hostNetwork, hostIPC         │    │
│  │ /var/lib/registry    │    │ runtimeClassName: nvidia     │    │
│  │   (150Gi hostPath)   │    │ Guaranteed QoS (8 CPU/16Gi)  │    │
│  └──────────┬───────────┘    └──────────┬───────────────────┘    │
│             │                           │                        │
│             │ pulls via containerd      │ exec / launch          │
│             │ hosts.toml routing        │                        │
│  ┌──────────┴──────────────┐  ┌─────────┴───────────────────┐    │
│  │ containerd              │  │ /root/foundation/...        │    │
│  │ + nvidia runtime        │  │ /data, /data2, /trainground │    │
│  │ (registered by          │  │ /dev, /dev/shm, /tmp …      │    │
│  │  scripts/*.sh)          │  │ host bind mounts            │    │
│  └──────────┬──────────────┘  └─────────────────────────────┘    │
│             │ on miss / fallthrough                              │
└─────────────┼────────────────────────────────────────────────────┘
              ▼
       registry-1.docker.io   ←── only when local registry returns 404
```

**What's deployed.** A single `positronic-control` Deployment in the
`positronic` namespace, plus the supporting `k0s-registry` Deployment in
`registry` and a cluster-scoped `RuntimeClass` named `nvidia`. Everything
else (argus, nimbus, dma-video) is pre-existing and unchanged.

**Where.** Single-node k0s on each robot, controller+worker. mk09 is the
only robot wired up so far; argentum has a stub overlay but isn't using
the positronic stack yet.

**Why this shape.** Three forces:
- The pod is a **persistent dev harness** more than a service — the
  default mode is `sleep infinity`, operators `kubectl exec` in and run
  ROS by hand. A ConfigMap toggle (`PHANTOM_CMD`) flips it to service
  mode. (Decision **D5** in the migration plan.)
- The robot may lose DockerHub access. Anything required for the pod
  to start needs to come from the local registry. Hence the priority-
  ordered mirror with DockerHub fallback.
- GPU access on k0s without the device plugin requires
  `nvidia-container-runtime` + a named RuntimeClass — straight
  `privileged` + `/dev` mount gives you the device nodes but no
  userspace driver libs, so `libcuda.so` fails to load.

---

## 2. The two repos

The positronic-control deployment spans two git repositories:

| Repo | Role |
|---|---|
| `Phantom-OS-KubernetesOptions` (this one) | **Deployment manifests** — everything in `manifests/`, `gitops/`, `scripts/`, `terraform/`. ArgoCD watches this repo. |
| `imu-policy/positronic_control` | **Image source** — Dockerfiles under `docker/`, ROS2 workspace under `workspace/`. This is where `docker build -t localhost:5443/positronic-control:<tag> .` runs from. |

Boundary: this repo never knows about the contents of the
positronic-control image — only its tag in
[`manifests/robots/mk09/kustomization.yaml`](../manifests/robots/mk09/kustomization.yaml)
under `images:`. Bumping the tag is the only thing that crosses the
boundary.

The build host (mk09 itself, today) is the one place where both repos
matter at once: image build happens in the positronic_control checkout,
push goes to the local registry on the same host, then the tag bump in
*this* repo wires the new image into the pod spec.

---

## 3. Three images and their roles

### 3.1 `localhost:5443/positronic-control:<tag>` — the executing image

The image the pod actually runs. Currently a retag of
`foundationbot/phantom-cuda:0.2.44-cu130` (a CUDA + ROS2 jazzy +
positronic_control workspace base). The `<tag>` is whatever was last
pushed and pinned in the mk09 overlay's `images:` block — see the
cheatsheet for the bump procedure.

The image's contract:
- Has `/opt/ros/<distro>/setup.bash`, `/amr_ws/install/setup.bash`, and
  `/src/workspace/install/setup.bash` (sourced opportunistically — any
  of them missing is fine).
- Sets `ROS_DISTRO` in env (currently `jazzy`).
- Working dir is overridden to `/src/workspace` by the manifest.

The image is **not** the thing the operator iterates on day to day —
they iterate on the bind-mounted source tree at `/src` (host:
`/root/foundation/DMA/positronic_control`). `colcon build` writes back
into the host tree, so the build artefacts survive pod restarts.

### 3.2 `localhost:5443/phantom-models:<tag>` — model bytes

A `FROM busybox:1.36.1` image whose only payload is the bundled model
weights + configs at `/models`. Built by
[`scripts/phantom-models/build.py`](../scripts/phantom-models/build.py).
The image is mounted indirectly: the pod's `load-models` initContainer
runs `cp -a /models/. /shared/` into a shared `emptyDir`, which the
main container then mounts at `/root/models` read-only.

Why busybox and not `FROM scratch`: the original design used a
Kubernetes `image:` volume (KEP-4639) with a scratch image, but k0s
1.35.3's containerd has only partial support — kubelet pulls the image,
containerd then fails OCI spec generation with `mkdir ""`. The §3.6a
fallback (initContainer + emptyDir copy) needs `sh + cp` in the image,
hence busybox. Roughly 5 MB on top of the 1+ GB of weights. (Decision
**D3** in the plan, revised 2026-04-26.)

The same `images:` transformer in the mk09 overlay rewrites both the
main container's `positronic-control` image *and* the initContainer's
`phantom-models` image — Kustomize walks initContainers too, so a
single `images:` entry per repo covers both.

### 3.3 `localhost:5443/library/registry:2` and friends — local registry contents

Everything else the cluster pulls — `mongo:7`, `redis:7-alpine`,
`postgres:16`, `nginx:latest`, `bluenviron/mediamtx:latest`,
`registry:2` itself, foundationbot/* qa images — gets primed into the
local registry by
[`scripts/prime-registry-cache.sh`](../scripts/prime-registry-cache.sh).
The script takes care of the `mongo:7 → localhost:5443/library/mongo:7`
path normalization so containerd's hosts.toml routing finds them.

The local registry isn't a pull-through proxy. Distribution `registry:2`
goes read-only when `REGISTRY_PROXY_REMOTEURL` is set, which would
block `docker push` of locally-built images. Instead, the script fills
the cache on a manual / scheduled basis. See
[plans/2026-04-24-local-registry-with-fallback.md](plans/2026-04-24-local-registry-with-fallback.md)
for the proxy-vs-push tradeoff.

---

## 4. Storage layers

```
                        ┌────────────────────────────┐
   docker push ────────▶│  k0s-registry pod          │
                        │  registry:2                │
                        │  /var/lib/registry         │
                        │     │ hostPath PV (Retain) │
                        └─────┼──────────────────────┘
                              ▼
                        host:/var/lib/registry  (150Gi)

   pod pull request:
   "docker.io/foundationbot/argus.auth:qa"
                              │
                              ▼
              containerd hosts.toml /etc/k0s/containerd.d/hosts/docker.io/hosts.toml
                              │
              ┌───────────────┴──────────────┐
              ▼ first try (override_path)    ▼ on 404 / unreachable
   http://localhost:5443                 https://registry-1.docker.io
   (LAN speed, offline-resilient)         (upstream truth)
```

### 4.1 Local registry storage

[`manifests/base/registry/registry.yaml`](../manifests/base/registry/registry.yaml)
declares:
- `PersistentVolume` `k0s-registry-pv` — `hostPath: /var/lib/registry`,
  150Gi, `persistentVolumeReclaimPolicy: Retain`.
- `PersistentVolumeClaim` `k0s-registry-pvc` — claims the PV by name
  (`claimRef`).
- `Deployment` `k0s-registry` — single replica, `hostNetwork: true`,
  `Recreate` strategy (RWO PVC + hostPort = no rolling overlap),
  binds `127.0.0.1:5443`, probes on `host: 127.0.0.1` since the
  registry doesn't listen on the pod IP.

The 150Gi capacity is enough headroom for a few `phantom-cuda` variants
(~37 GB each) plus the rest of the cluster's primed images. hostPath
PVs aren't enforced by k8s — the real cap is whatever `/var/lib/registry`
has on disk.

### 4.2 containerd hosts.toml routing

Written by
[`scripts/configure-k0s-containerd-mirror.sh`](../scripts/configure-k0s-containerd-mirror.sh)
to `/etc/k0s/containerd.d/hosts/docker.io/hosts.toml`. The script also:
- Adds `localhost:5443` to `/etc/docker/daemon.json` `insecure-registries`
  so `docker push` over plain HTTP works.
- Drops `/etc/k0s/containerd.d/10-registry-mirror.toml` declaring
  `config_path = /etc/k0s/containerd.d/hosts`.
- Edits `/etc/k0s/containerd.toml` to import that drop-in (k0s does
  not auto-import `/etc/k0s/containerd.d/*.toml` — the imports
  directive has to be present in the main config).
- Restarts docker + k0s.

The hosts.toml routing applies to **every** `docker.io/*` pull, so the
cache benefit is cluster-wide once an image is primed.

---

## 5. Pod composition

Source: [`manifests/base/positronic/positronic-control.yaml`](../manifests/base/positronic/positronic-control.yaml).
Walking the spec field by field.

### 5.1 Network + IPC

```yaml
hostNetwork: true
hostIPC: true
dnsPolicy: ClusterFirstWithHostNet
```

`hostNetwork` because the ROS2 stack uses FastDDS / discovery on host
ports and shares the network with the motor controller systemd
service. `hostIPC` because some IPC paths (`/dev/shm` segments) are
shared with host processes. `ClusterFirstWithHostNet` lets the pod
still resolve `*.svc.cluster.local` despite having the host's
resolv.conf.

### 5.2 GPU runtime

```yaml
runtimeClassName: nvidia
```

The named RuntimeClass at
[`manifests/base/runtime-classes/nvidia.yaml`](../manifests/base/runtime-classes/nvidia.yaml)
points at the `nvidia` containerd runtime registered by
[`scripts/configure-k0s-nvidia-runtime.sh`](../scripts/configure-k0s-nvidia-runtime.sh).
That script writes `/etc/k0s/containerd.d/20-nvidia-runtime.toml`
declaring the runtime as `runc.v2` with `BinaryName =
/usr/bin/nvidia-container-runtime`. Crucially it does **not** set
`SystemdCgroup` — k0s's default runtime uses cgroupfs, and a mismatch
fails sandbox creation with `expected cgroupsPath to be of format
slice:prefix:name`.

The runtime's job is to bind-mount the host's NVIDIA driver libs +
Tegra device bits at container start. Without it, the pod still gets
`/dev/nvidia*` device nodes (via `privileged: true` + the `/dev`
hostPath), but `libcuda.so` is missing.

(Decision **D6** scope — the NVIDIA k8s device plugin is the future,
out of scope for this stack today.)

### 5.3 initContainer + main container

```
┌─────────────────────────────────────────────────┐
│ initContainer: load-models                      │
│   image: localhost:5443/phantom-models:<tag>    │
│   cmd:   cp -a /models/. /shared/               │
│   mount: emptyDir "models" → /shared            │
│   resources: 1 CPU / 1Gi requests==limits       │
└─────────┬───────────────────────────────────────┘
          │ runs once at pod start (~10–30s)
          ▼
┌─────────────────────────────────────────────────┐
│ container: positronic-control                   │
│   image: localhost:5443/positronic-control:<t>  │
│   workingDir: /src/workspace                    │
│   args: bash -c "<dispatch on $PHANTOM_CMD>"    │
│   envFrom: ConfigMap positronic-config          │
│   env:    8 hardcoded image-contract values     │
│   mounts: 10 hostPath + 1 emptyDir              │
│   resources: 8 CPU / 16Gi requests==limits      │
│   securityContext.privileged: true              │
└─────────────────────────────────────────────────┘
```

Both containers must declare `requests == limits` for the pod to be
**Guaranteed QoS**. Without that, k0s CPU Manager won't pin onto
specific cores. The init's 1 CPU / 1Gi over-allocation for ~30 s is
worth the QoS guarantee.

### 5.4 Mounts

10 hostPath mounts + 1 emptyDir for `/root/models`:

| Mount | Source | Why |
|---|---|---|
| `/dev/shm`     | host `/dev/shm`                                              | ROS2 FastRTPS / CycloneDDS shared memory |
| `/dev`         | host `/dev`                                                  | GPU device nodes, IMU, EtherCAT, cameras |
| `/tmp`         | host `/tmp`                                                  | IPC files, X11 unix socket parent |
| `/src`         | host `/root/foundation/DMA/positronic_control`               | The essential mount — colcon builds land back on host |
| `/root/.ihmc`  | host `/root/foundation/DMA/positronic_control/workspace/.ihmc` | IHMC runtime config |
| `/data`        | host `/data`                                                 | data partition |
| `/data2`       | host `/data2`                                                | data partition |
| `/trainground` | host `/root/trainground`                                     | training ground data |
| `/recordings`  | host `/root/recordings`                                      | shared with dma-video / nimbus |
| `/root/.cache/torch/hub` | host `/data/torch`                                 | torch hub cache |
| `/root/models` | emptyDir, populated by `load-models` initContainer (read-only) | model weights from phantom-models image |

Compose mounts dropped during migration (decisions **D1**, **D2**, plan
§3.6): `/nix/store`, X11 socket + auth, `~/.gradle`, host-side
`/root/phantom-models-merged`. They're added back temporarily by patch
when an operator needs them.

### 5.5 envFrom + hardcoded env

```yaml
envFrom:
  - configMapRef:
      name: positronic-config
      optional: true
env:
  - { name: PHANTOM_MODELS,                  value: /root/models }
  - { name: RMW_IMPLEMENTATION,              value: rmw_fastrtps_cpp }
  - { name: FASTRTPS_DEFAULT_PROFILES_FILE,  value: /src/workspace/fastdds_config.xml }
  - { name: ACCEPT_EULA,                     value: "Y" }
  - { name: HF_HUB_OFFLINE,                  value: "1" }
  - { name: HF_HUB_CACHE,                    value: /root/.cache/huggingface/hub }
  - { name: TRANSFORMERS_CACHE,              value: /root/.cache/huggingface/hub }
  - { name: TORCH_HOME,                      value: /root/.cache/torch/hub }
```

Two-tier env: image-contract values that never vary per robot (in-
container canonical paths, FastRTPS profile path, EULA, HF offline
flag) are **hardcoded** in the manifest. Tunables that legitimately
vary (`ROS_DOMAIN_ID`, `PHANTOM_CMD`) live in the
`positronic-config` ConfigMap and are pulled in via `envFrom`.

`optional: true` means the pod starts even if the ConfigMap is
missing, which is a safety net rather than the primary contract — in
practice the base ConfigMap always ships, defaulting `ROS_DOMAIN_ID:
"1"` and `PHANTOM_CMD: ""`.

### 5.6 args — dispatch on PHANTOM_CMD

```yaml
args:
  - /bin/bash
  - -c
  - |
    if [ -n "${PHANTOM_CMD:-}" ]; then
      source /opt/ros/${ROS_DISTRO}/setup.bash 2>/dev/null || true
      source /amr_ws/install/setup.bash         2>/dev/null || true
      source /src/workspace/install/setup.bash  2>/dev/null || true
      exec bash -c "${PHANTOM_CMD}"
    else
      exec sleep infinity
    fi
```

Empty `PHANTOM_CMD` → `sleep infinity`, operator execs in. Populated →
source ROS overlays best-effort, then exec the launch command. `exec`
makes the chosen process PID 1 for clean SIGTERM handling on rollout
restart. The `2>/dev/null || true` chain prevents a missing overlay
(e.g. `install/setup.bash` not yet built) from killing the whole
container.

### 5.7 Resources

`requests: 8 CPU / 16Gi`, `limits: 8 CPU / 16Gi`. The whole-number CPU
+ requests=limits is what makes the pod Guaranteed QoS, which is the
only QoS class k0s CPU Manager pins onto specific cores. The
reserved-core policy in `/etc/k0s/k0s.yaml` already excludes the cores
held by the host (motor controller, EtherCAT, etc.) — see the README
for the full table.

(Decision **D6** — no explicit `cpuset` on the pod. Compose used
`cpuset: 0-9`; we trade that for declarative cluster-level policy.)

---

## 6. Per-robot overlay model

```
manifests/
├── base/
│   ├── positronic/                   # generic — same on every robot
│   │   ├── namespace.yaml
│   │   ├── configmap.yaml            # ROS_DOMAIN_ID=1, PHANTOM_CMD=""
│   │   ├── positronic-control.yaml   # the Deployment
│   │   └── kustomization.yaml
│   ├── registry/
│   ├── runtime-classes/              # nvidia RuntimeClass
│   └── argus, nimbus, dma-video/     # the other stacks
└── robots/
    ├── mk09/                         # one folder per robot
    │   ├── kustomization.yaml        # composes base/* + pins images + patches
    │   └── patches/
    │       └── operator-ui-env.yaml
    └── argentum/
```

The base manifests don't pin any registry-specific tags — they declare
`localhost:5443/positronic-control:PLACEHOLDER` and
`localhost:5443/phantom-models:PLACEHOLDER`. The per-robot overlay's
`images:` transformer rewrites the tag part:

```yaml
# manifests/robots/mk09/kustomization.yaml
images:
  - name: localhost:5443/positronic-control
    newTag: 0.2.44-cu130
  - name: localhost:5443/phantom-models
    newTag: 2026-04-26
```

A robot that wants a different `ROS_DOMAIN_ID` patches the
`positronic-config` ConfigMap from its overlay's `patches:` block —
mk09 currently inherits the base default per decision **D4**.

### Onboarding a new robot

```
cp -r manifests/robots/mk09 manifests/robots/<new>
# edit manifests/robots/<new>/kustomization.yaml:
#   - bump images: tags to whatever was pushed on that robot
#   - add ConfigMap patches if its ROS_DOMAIN_ID / PHANTOM_CMD differ
# add gitops/apps/phantomos-<new>.yaml pointing at manifests/robots/<new>
# git push, ArgoCD picks it up
```

The `images:` transformer rewrites both the main container and the
initContainer — no separate patch needed for `phantom-models` (this
was simplified in commit `ba8726f`).

---

## 7. ArgoCD wiring

### 7.1 Topology

```
   ┌─────────────────────────────────┐
   │ Application: root               │   gitops/root-app.yaml
   │   path: gitops/apps             │   (applied once by terraform)
   │   recurse: true, prune, selfHeal│
   └────────────────┬────────────────┘
                    │ watches gitops/apps/*.yaml
                    ▼
   ┌─────────────────────────────────┐   gitops/apps/phantomos-mk09.yaml
   │ Application: phantomos-mk09     │
   │   path: manifests/robots/mk09   │
   │   targetRevision: main          │   ◀── branch work invisible to ArgoCD
   │   prune, selfHeal               │       until merged
   │   ServerSideApply               │
   └────────────────┬────────────────┘
                    │ kustomize build manifests/robots/mk09/
                    ▼
              All workloads on mk09
```

[`gitops/root-app.yaml`](../gitops/root-app.yaml) is the **app-of-apps**
root. It watches `gitops/apps/` recursively — drop a new
`Application` YAML there and ArgoCD adopts it; delete one and (with
`prune: true`) ArgoCD removes the child Application and cascades the
deletion to its workloads.

[`gitops/apps/phantomos-mk09.yaml`](../gitops/apps/phantomos-mk09.yaml)
is the per-robot Application. It points at
`manifests/robots/mk09/` on `targetRevision: main`.

### 7.2 Pre-merge testing on a feature branch

Because `targetRevision: main`, work on `feat/local-registry-mirror`
**isn't seen** by ArgoCD until the branch merges. During branch work,
apply manually on the robot:

```bash
sudo k0s kubectl apply -k manifests/robots/mk09/
```

This is what's been happening on mk09 throughout this branch's work.
ArgoCD also doesn't fight the manual apply — `selfHeal` only kicks in
when ArgoCD's *own* tracked objects drift, and during branch work the
manifests on disk match what's been applied.

The ArgoCD-tracked state catches up on merge: ArgoCD diffs `main`
against the live cluster and applies the delta (which should be zero
if the branch was applied correctly).

### 7.3 syncPolicy.automated.prune + selfHeal

```yaml
syncPolicy:
  automated:
    prune: true       # delete cluster objects when YAML is removed from git
    selfHeal: true    # revert manual edits ArgoCD didn't author
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
```

`prune: true` on the per-robot Application means deleting a YAML from
`manifests/robots/mk09/` removes the resource from the cluster. The
root Application also has `prune: true` so deleting a file from
`gitops/apps/` removes the corresponding child Application + all of
its workloads.

`selfHeal: true` reverts manual edits within ~3 min. If we edit a Pod
spec via `kubectl edit` post-merge, ArgoCD undoes it — useful as a
guardrail, occasionally annoying when iterating. The escape hatch is
to either commit the change to git or temporarily set `selfHeal:
false`.

### 7.4 Bootstrapping ArgoCD on a fresh cluster

[`terraform/main.tf`](../terraform/main.tf) does it in three resources:

```bash
cd terraform
terraform init
terraform apply
```

Steps:
1. Create the `argocd` namespace.
2. `helm_release` of `argo-cd` with NodePort service for the UI.
3. `null_resource` with `local-exec` that `kubectl apply -f
   ../gitops/root-app.yaml`. (Native `kubernetes_manifest` would
   require the `Application` CRD at plan time — local-exec dodges
   that.)

After `terraform apply`, every other change should flow through git →
ArgoCD; nothing else gets `kubectl apply`'d by hand. The exceptions
documented in [terraform/README.md](../terraform/README.md) are k0s
itself, the `dockerhub-creds` Secret per namespace, and ArgoCD's
admin password.

### 7.5 Sync / refresh / force reconcile

```bash
# soft refresh (recheck git, sync if drift detected)
sudo k0s kubectl -n argocd annotate app phantomos-mk09 \
  argocd.argoproj.io/refresh=normal --overwrite

# hard refresh (recheck git + cluster cache)
sudo k0s kubectl -n argocd annotate app phantomos-mk09 \
  argocd.argoproj.io/refresh=hard --overwrite

# explicit sync (forces an apply pass even if "Synced")
argocd app sync phantomos-mk09
argocd app wait phantomos-mk09 --health --timeout 300
```

### 7.6 Drift handling

If something drifts (we manually create a PVC out-of-band, like the
registry PV expansion case), ArgoCD treats the live object as
out-of-sync. Two paths:

1. **Adopt the drift back into git.** Edit the manifest to match the
   live state, commit, push. ArgoCD goes back to Synced.
2. **Discard the drift.** With `selfHeal: true` ArgoCD does this on
   its own within ~3 min. To force it now: `argocd app sync
   phantomos-mk09 --force`.

The PVC resize case (cheatsheet § Resize the registry PVC) is path 1 —
edit `registry.yaml` capacity to match the new size, commit, ArgoCD
re-syncs to Synced state.

---

## 8. Why we chose what we chose

The decision history (D1–D7) lives in
[`plans/2026-04-24-positronic-k0s-migration.md` § 4](plans/2026-04-24-positronic-k0s-migration.md#4-decisions),
captured in a 2026-04-25 review session. Don't restate it here; pointers:

- **D1** — drop `/nix/store` mount.
- **D2 + D3** — models served from a dedicated container image. The
  delivery mechanism revised on 2026-04-26 from native KEP-4639
  `image:` volume to `initContainer + emptyDir` (k0s 1.35.3 containerd
  doesn't fully support image volumes). See the §3.6a note in the
  plan.
- **D4** — mk09 inherits `ROS_DOMAIN_ID` base default (1).
- **D5** — single Deployment toggled via ConfigMap (`PHANTOM_CMD`),
  not two separate Deployments.
- **D6** — trust k0s CPU Manager + Guaranteed QoS, no explicit cpuset.
- **D7** — archive `development.docker-compose.yaml` once k0s pod is
  green.

The local-registry choices (proxy mode rejected, push-only registry +
prime script, port 5443 instead of 5000, hostNetwork + 127.0.0.1 bind)
are similarly captured in
[`plans/2026-04-24-local-registry-with-fallback.md`](plans/2026-04-24-local-registry-with-fallback.md).

---

## 9. Known limitations

**Image volumes (KEP-4639) not used.** k0s 1.35.3's containerd has
only partial support — kubelet pulls the image but containerd fails
OCI spec generation with `mkdir ""`. We use the
`initContainer + emptyDir` fallback documented in the plan's §3.6a.
Cost: ~10–30 s of copy at every pod start (depends on bundle size, in
practice 1–37 GB), and `/root/models` lives on the kubelet's pod-volumes
disk rather than backed by a content-addressed image. The source of
truth is still the registry-pinned image tag, so re-population is
deterministic. Switch back when k0s catches up — the manifest diff is
small.

**Models bundled in image require rebuild for any model change.** Even
swapping a single weights file means re-running
`scripts/phantom-models/build.py`, pushing a new tag, and bumping the
overlay. Acceptable for the current cadence (models change rarely);
if it becomes painful, the next steps are either (a) an `image:`
volume once k0s supports it (no copy on start), or (b) a per-model
PVC backed by an NFS / object-store mount.

**PVC resize on hostPath PVs requires recreate dance.** hostPath PVs
aren't dynamically resizable. To grow `/var/lib/registry` past 150Gi,
follow the cheatsheet § Resize the registry PVC procedure. Data on
disk is preserved (`Retain` reclaim policy) — only the PV/PVC objects
get recreated.

**Registry isn't HA.** Single replica, single hostPath, RWO. Loss of
`/var/lib/registry` means a re-prime from upstream. That's fine for
the current single-robot deployments; if we ever run a multi-node k0s
where the registry must be pulled across nodes, the registry needs to
move to either a CSI-backed PV or an off-node object store.

**Branch work is invisible to ArgoCD.** `targetRevision: main` means
every change has to land on `main` to be reconciled. Pre-merge testing
on the robot is `kubectl apply -k` by hand. Trade-off: simpler topology
(no per-branch ArgoCD environments), at the cost of a manual apply
window between push and merge.

**`privileged: true` on positronic-control.** Mirrors compose's
behavior — needed for the GPU Tegra device nodes + raw IMU/EtherCAT/
camera access. Drop when the NVIDIA k8s device plugin is in and the
full device list is enumerated. Out of scope for the current rollout.
