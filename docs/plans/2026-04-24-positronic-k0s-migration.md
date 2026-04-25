# Plan: migrate positronic-control from docker-compose to k0s

**Date:** 2026-04-24
**Status:** Draft — for review, not yet executed
**Scope:** Replace the `phantom` service in
`imu-policy/positronic_control/docker/development.docker-compose.yaml` +
`.env` with a declarative k0s Deployment managed through this repo.

---

## 1. Context

Today positronic-control runs on mk09 via `docker compose up` using
`development.docker-compose.yaml`. The compose file defines:

- one `phantom` service (nine others commented out)
- ~20 environment variables sourced from a per-host `.env`
- 15 bind-mounts connecting the container to host paths
- an entrypoint that sources ROS overlays then launches a ros2 node
- privileged mode, host networking, GPU access via compose's `capabilities: [gpu]`

The operator pattern is actually: "`command` tries to source a path that doesn't
exist on this image; the trailing `|| sleep infinity` keeps the container up;
the operator `docker exec`s in to do real work." That's the envelope we need to
preserve — the pod is mainly a persistent development harness, not a
run-and-exit service.

### Why migrate

1. **One control plane.** Everything else on mk09 (argus, nimbus, dma-video,
   registry) already runs through k0s + ArgoCD. `docker compose` is the odd
   one out — separate lifecycle, separate restart policy, no visibility from
   `kubectl get pods`, no GitOps sync.
2. **Unified image delivery.** With the local registry in place, positronic
   can pull from `localhost:5443/positronic-control:<tag>` the same way
   everything else does.
3. **Uniform CPU/GPU accounting.** k0s CPU Manager respects the reserved-core
   policy declared in `k0s.yaml`; compose's `cpuset` is independent of that
   and can allocate cores that k0s also hands out to other pods.
4. **Declarative per-robot config.** A robot overlay patches one ConfigMap
   instead of editing a `.env` file by hand on each machine.

### Why not migrate

- The compose flow works today. A migration is optional, not forced by any
  deadline.
- The docker container's dev-UX (exec in, colcon build, iterate) transfers
  cleanly to `kubectl exec`, but anything that breaks muscle memory is a
  real cost.
- Some compose features (`depends_on`, named volumes, named networks) have
  k8s equivalents but shape the manifests differently. We'll touch each.

---

## 2. Current state in detail

### 2.1 `development.docker-compose.yaml` (phantom service)

```yaml
services:
  phantom:
    image: ${PHANTOM_IMAGE}:${PHANTOM_IMAGE_TAG}
    container_name: ${PHANTOM_CONTAINER_NAME:-positronic_phantom}
    privileged: true
    cpuset: "${CPUSET:-0-9}"
    environment:
      - DISPLAY=${DISPLAY}
      - XAUTHORITY=${XAUTH}
      - LOGNAME=${USER}
      - ACCEPT_EULA=${ACCEPT_EULA:-Y}
      - ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-101}
      - TORCH_HOME=${TORCH_HOME}
      - PHANTOM_MODELS=/root/models               # fixed in-container
      - HF_HUB_CACHE=${HF_HUB_CACHE}
      - HF_HUB_OFFLINE=1
      - TRANSFORMERS_CACHE=${HF_HUB_CACHE}
      - FASTRTPS_DEFAULT_PROFILES_FILE=/src/workspace/fastdds_config.xml
    working_dir: /src/workspace
    command: ["bash", "-c", "source ... && ${PHANTOM_CMD:-ros2 launch srg_localization global_positioning_launch.py} || sleep infinity"]
    volumes:
      - ${XSOCK}:${XSOCK}:rw                      # X11 socket — dev only
      - ${XAUTH}:${XAUTH}:rw                      # X11 auth   — dev only
      - ${HOME}/recordings:/recordings
      - ${HOME}/trainground:/trainground
      - /data:/data
      - /data2:/data2
      - ${HOME}/.gradle:/root/.gradle             # build-time cache only
      - ${REPO_ROOT}:/src
      - ${REPO_ROOT}/workspace/.ihmc:/root/.ihmc
      - /tmp:/tmp
      - /dev:/dev
      - /dev/shm:/dev/shm
      - ${TORCH_HOME}:/root/.cache/torch/hub
      - ${PHANTOM_MODELS:-/root/models}:/root/models    # replaced by image-volume mechanism — see §3.6a
      - /nix/store:/nix/store                           # removed during k0s migration
    deploy.resources.reservations.devices: [{capabilities: [gpu]}]
    shm_size: 2g
    network_mode: host
```

### 2.2 `.env` (per-host, typically `git ignore`d)

Illustrative set of interpolations compose reads:

- `PHANTOM_IMAGE`, `PHANTOM_IMAGE_TAG`
- `HOME`, `USER`, `DISPLAY`, `XAUTH`, `XSOCK`
- `REPO_ROOT` — the positronic_control checkout on the host
- `PHANTOM_MODELS` — the **host path** that gets mounted to `/root/models`
- `TORCH_HOME`, `HF_HUB_CACHE`
- `ROS_DOMAIN_ID`, `ACCEPT_EULA`
- `CPUSET`
- `PHANTOM_CMD` — optional launch override
- `PHANTOM_CONTAINER_NAME`, `DOCKER_RUNTIME`
- `DMA_VIDEO_TAG` (for the commented-out services)

---

## 3. Target state

### 3.1 Replacement matrix

| compose concept | k0s equivalent |
|---|---|
| `services.phantom.image`              | `Deployment.spec.template.spec.containers[0].image`, rewritten per-robot via kustomize `images:` transformer |
| `container_name`                      | auto-generated pod name `positronic-control-<hash>`; no equivalent needed |
| `privileged: true`                    | `securityContext.privileged: true` |
| `network_mode: host`                  | `spec.hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet` |
| `cpuset: "0-9"`                       | **not** a direct equivalent — use Guaranteed QoS + k0s CPU Manager (allocatable pool already excludes reserved cores) |
| `environment` (static values)         | `containers[0].env:` — hardcoded values |
| `environment` (values from `.env`)    | `ConfigMap positronic-config`, consumed via `envFrom: configMapRef` |
| `working_dir`                         | `containers[0].workingDir` |
| `command`                             | `containers[0].args` (keeps image ENTRYPOINT) |
| `volumes` (bind mounts)               | `spec.volumes[*].hostPath` + `containers[0].volumeMounts` |
| `shm_size: 2g`                        | no direct equivalent; rely on host `/dev/shm` being sized right (it is — this is a host tuning, not a pod concern) |
| `deploy...capabilities: [gpu]`        | privileged + `/dev` today; `resources.limits.nvidia.com/gpu: 1` when the device plugin lands |
| `restart: unless-stopped`             | implicit — Deployment controller restarts pods |

### 3.2 File layout

```
manifests/
├── base/
│   └── positronic/
│       ├── namespace.yaml                        (exists, unchanged)
│       ├── configmap.yaml                        NEW — tunable defaults
│       ├── positronic-control.yaml               (update — envFrom, mounts, args)
│       └── kustomization.yaml                    (update — include configmap)
└── robots/
    └── mk09/
        ├── kustomization.yaml                    (add configmap patch)
        └── patches/
            └── positronic-config.yaml            NEW — mk09 overrides
```

### 3.3 Layered config (ConfigMap-driven)

Only values that legitimately vary between deployments live in the ConfigMap.
Image-contract values (in-container canonical paths) are hardcoded in the
manifest because changing them would also require changing the image build.

**Base ConfigMap (`manifests/base/positronic/configmap.yaml`):**

```yaml
data:
  ROS_DOMAIN_ID: "1"                     # default — see Decisions D4
  PHANTOM_CMD: ""                        # empty = sleep infinity, populated = launch
```

**Per-robot patch (`manifests/robots/mk09/patches/positronic-config.yaml`):**

mk09 currently uses the base default for `ROS_DOMAIN_ID` (decision **D4**),
so no overlay patch is required for this robot. The `patches/` directory
is kept (and an empty/placeholder patch file is fine) so future robot
overlays have a clear template — a robot that needs a different value
adds it here.

`MODELS_HOST_PATH` is **not** in the ConfigMap: models are delivered via
a dedicated container image (decisions **D2** + **D3**) — see §3.6a.

**Deployment consumption:**

```yaml
containers:
  - name: positronic-control
    envFrom:
      - configMapRef:
          name: positronic-config
          optional: true                  # pod starts even if CM missing
    env:
      # Hardcoded — contract with the image, never varies per robot
      - name: PHANTOM_MODELS
        value: /root/models
      - name: RMW_IMPLEMENTATION
        value: rmw_fastrtps_cpp
      - name: FASTRTPS_DEFAULT_PROFILES_FILE
        value: /src/workspace/fastdds_config.xml
      - name: ACCEPT_EULA
        value: "Y"
      - name: HF_HUB_OFFLINE
        value: "1"
      - name: HF_HUB_CACHE
        value: /root/.cache/huggingface/hub
      - name: TRANSFORMERS_CACHE
        value: /root/.cache/huggingface/hub
      - name: TORCH_HOME
        value: /root/.cache/torch/hub
```

If the ConfigMap is missing entirely, `envFrom` with `optional: true` silently
sets nothing. That means `ROS_DOMAIN_ID` is unset in that case, which ROS
defaults to 0 — **not** the "default to 1" semantics we want. So in practice
the base ConfigMap is always shipped and contains `ROS_DOMAIN_ID: "1"`.
Missing-CM behavior is a safety net, not the primary contract.

### 3.4 Entrypoint: default sleep infinity, operator-overridable

**Default behavior:** `sleep infinity`. The pod stays up; operators
`kubectl exec` in for interactive ROS work. This matches how the docker
container is actually used today (the `source /opt/ros/humble/...` chain
silently fails on the jazzy-built image and the `|| sleep infinity` fallback
is what runs).

**Operator model (decision D5):** a **single Deployment** named
`positronic-control`, with mode controlled by the `PHANTOM_CMD` key in
the ConfigMap. Empty → interactive (`sleep infinity`); populated → service
(`bash -c "$PHANTOM_CMD"`). Mode change = ConfigMap edit + `kubectl
rollout restart`. The rejected alternative (two separate Deployments,
`positronic-control-dev` + `positronic-control-service`) was considered
but adds GPU/CPU contention if both are scheduled and doubles the
manifest surface for negligible benefit.

**Override mechanism:** `PHANTOM_CMD` in the ConfigMap.

```yaml
# in Deployment.spec.template.spec.containers[0]
args:
  - /bin/bash
  - -c
  - |
    if [ -n "${PHANTOM_CMD:-}" ]; then
      # operator supplied a launch command via ConfigMap
      source /opt/ros/${ROS_DISTRO}/setup.bash 2>/dev/null || true
      source /amr_ws/install/setup.bash 2>/dev/null || true
      source /src/workspace/install/setup.bash 2>/dev/null || true
      exec bash -c "${PHANTOM_CMD}"
    else
      # default: keep the pod alive for interactive use
      exec sleep infinity
    fi
```

Notes:
- `exec sleep infinity` makes sleep PID 1 so SIGTERM handling is clean.
- `2>/dev/null || true` on each `source` line prevents a missing overlay
  from nuking the whole command — same spirit as the compose `|| sleep infinity`
  fallback but explicit about which sources are best-effort.
- `ROS_DISTRO` comes from the image's own env (jazzy in the current
  aarch64 build) — the entrypoint script sets it before running `args`.
- Setting `PHANTOM_CMD: "ros2 launch srg_localization global_positioning_launch.py"`
  in the ConfigMap flips the pod from interactive-dev mode to service
  mode without re-rolling the image.

### 3.5 Host paths and the "ConfigMap can't drive hostPath" wall

`envFrom` injects env vars into the *container*. A Pod's
`volumes[].hostPath.path` is a **static string** in the manifest — k8s
does not template it from a ConfigMap at deploy time. This was a real
problem when models lived at a per-robot host path
(`/root/phantom-models-merged` on aarch64, `/nix/store/...` on x86-nix).

**Resolved by D2 + D3:** models now ship as a dedicated container image
(`localhost:5443/phantom-models:<tag>`) mounted via the Kubernetes
`image:` volume source — see §3.6a. The host path goes away entirely;
the same manifest works on every robot.

If a future variable host-path question arises for some other mount
(unlikely given the current mount diet), the original three options
remain available: per-robot volume patch, symlink normalization, or
per-robot `PersistentVolume`. None are in use today.

### 3.6 Mounts — what stays, what goes

Going from 15 compose bind-mounts to a leaner k8s set:

| compose mount | kept? | notes |
|---|---|---|
| `${XSOCK}:${XSOCK}` (X11 socket)         | **no**  | dev-only; operator can add temporarily for GUI work |
| `${XAUTH}:${XAUTH}`                      | **no**  | ephemeral tmpfile; not stable across reboots |
| `${HOME}/recordings:/recordings`         | yes     | |
| `${HOME}/trainground:/trainground`       | yes     | |
| `/data:/data`, `/data2:/data2`           | yes     | |
| `${HOME}/.gradle:/root/.gradle`          | **no**  | build-time cache only; not needed for runtime |
| `${REPO_ROOT}:/src`                      | yes     | the essential mount — colcon builds land back on host |
| `${REPO_ROOT}/workspace/.ihmc:/root/.ihmc` | yes   | |
| `/tmp:/tmp`                              | yes     | IPC files, X11 unix socket parent |
| `/dev:/dev`                              | yes     | GPU device nodes, IMU, EtherCAT, cameras |
| `/dev/shm:/dev/shm`                      | yes     | ROS2 FastRTPS/CycloneDDS IPC |
| `${TORCH_HOME}:/root/.cache/torch/hub`   | yes     | |
| `${PHANTOM_MODELS}:/root/models`         | **replaced** | now an image-volume mount — see §3.6a (D2 + D3) |
| `/nix/store:/nix/store`                  | **no**  | binaries no longer reference /nix/store paths on this robot (D1) |

Dropped mounts can be added temporarily by patching the Deployment when
an operator needs them (e.g. to run an rviz session over X11).

### 3.6a Models image

Decisions **D2** + **D3**: model artefacts are delivered as a dedicated
container image, mounted into the pod via the Kubernetes `image:` volume
source ([KEP-4639](https://github.com/kubernetes/enhancements/tree/master/keps/sig-storage/4639-oci-volume-source)).
This decouples models from per-robot host paths — the same manifest
works on every robot, and a new model set is shipped by tag bump in
git rather than `rsync`-ing a directory onto each machine.

**Why a dedicated image (vs. hostPath):**
- One canonical place for the bytes (the registry); robots stay clean.
- Tag-bump-in-git replaces ad-hoc edits to `/root/phantom-models-merged`.
- Image content is content-addressed (digests) — drift is detectable.

**Build/push loop** — the build is wrapped by
[`scripts/phantom-models/build.py`](../../scripts/phantom-models/build.py)
which calls `docker build` against the `FROM scratch` Dockerfile in the
same directory and then pushes:

```bash
# Default: bundle /root/phantom-models-merged with today's date as the tag
sudo python3 scripts/phantom-models/build.py

# Explicit per-model curation via a YAML manifest
sudo python3 scripts/phantom-models/build.py \
  --manifest scripts/phantom-models/models.example.yaml \
  --tag 2026-04-25
```

The Dockerfile is intentionally trivial:

```Dockerfile
FROM scratch
COPY . /models
```

`FROM scratch` is fine — the image is mounted as a read-only volume,
never executed. The build context is either the source directory passed
to `--source` (zero-copy `docker build /path/to/dir`) or a temp dir
assembled from the `--manifest` entries.

**Tag scheme** — date-based (`YYYY-MM-DD`), set as the script's default
via `today_tag()`. Override with `--tag` if multiple builds happen in a
single day or if you'd rather identify by content hash / version.

**Pod consumption** (illustrative; final shape in the manifest):

```yaml
volumes:
  - name: models
    image:
      reference: localhost:5443/phantom-models:<tag>
      pullPolicy: IfNotPresent
containers:
  - name: positronic-control
    volumeMounts:
      - name: models
        mountPath: /root/models
        readOnly: true
```

Zero copy at pod start: the bytes live in containerd's content store
and the pod gets a read-only view.

**Prerequisite check (must verify before §3.6a applies):**

```bash
sudo k0s version             # need k8s >= 1.31 (alpha) or >= 1.33 (beta)
```

If the `ImageVolume` feature gate is not on, enable it in `k0s.yaml`:

```yaml
spec:
  api:
    extraArgs:
      feature-gates: ImageVolume=true
  workerProfiles:
    - name: default
      values:
        featureGates:
          ImageVolume: true
```

`k0s.yaml` edit + `k0s restart` is required for the gate to take effect.

**Fallback (footnote):** if k0s does not support image volumes (e.g. an
older worker), use an `initContainer` that copies the image's `/models`
into a shared `emptyDir`, and have the main container mount that
`emptyDir` at `/root/models`. Documented for completeness; not the
primary path. Cost: ~37 GB copy at every pod start.

**Tag-bump path:** per-robot overlay rewrites `newTag` for both
`localhost:5443/positronic-control` and
`localhost:5443/phantom-models` in
`manifests/robots/<robot>/kustomization.yaml`. Same mechanism the
positronic-control image already uses.

(Tag scheme is set via `build.py`'s default; documented above.)

### 3.7 Resources

- **CPU:** `requests: 8` / `limits: 8`. Decision **D6** is to trust the
  k0s CPU Manager: Guaranteed QoS (whole-number CPU, requests=limits)
  tells the CPU Manager to pin onto specific cores from the
  allocatable pool, honoring the reserved-core policy already declared
  in `k0s.yaml`. The pod manifest does **not** set an explicit `cpuset`
  — that would diverge from how every other workload on the cluster is
  scheduled and require either privileged kernel knobs or a custom
  CPUManager policy option. Compose's `cpuset "0-9"` was machine-local
  state; we trade it for declarative cluster-level policy.
- **Memory:** `requests: 16Gi` / `limits: 16Gi`. Compose sets no memory
  limit; 16Gi is a reasonable first guess for a CUDA ROS2 stack. Bump
  if we see OOMs.
- **GPU:** today, `privileged: true` + `/dev` mount. When the NVIDIA k0s
  device plugin is installed, switch to `resources.limits.nvidia.com/gpu: 1`
  and drop privileged (plus /dev mount scope). Out of scope for this plan.

---

## 4. Decisions

All open questions from the original draft are resolved (review session
2026-04-25). Decision log is also captured in
[`.claude/plans/this-is-no-longer-effervescent-popcorn.md`](../../../.claude/plans/this-is-no-longer-effervescent-popcorn.md).

| ID | Decision | Notes |
|----|----------|-------|
| **D1** | Drop `/nix/store` mount | Binaries on this robot no longer reference `/nix/store` paths. |
| **D2** | Models served from a dedicated container image | Decouples models from per-robot host paths; tag bumps in git replace `rsync`/manual edits. |
| **D3** | Mechanism: native Kubernetes `image:` volume (KEP-4639) | Zero-copy, declarative. Requires k0s with k8s ≥ 1.31 + `ImageVolume` feature gate. Fallback: initContainer + emptyDir copy. |
| **D4** | mk09 `ROS_DOMAIN_ID` = base default (1) | Base ConfigMap ships `ROS_DOMAIN_ID: "1"`. mk09 overlay does **not** patch it. |
| **D5** | `PHANTOM_CMD` → single Deployment toggled via ConfigMap | One `positronic-control` Deployment. Empty `PHANTOM_CMD` = `sleep infinity`; populated = service launch. Mode change = ConfigMap edit + `kubectl rollout restart`. |
| **D6** | CPU pinning → trust k0s CPU Manager | Guaranteed QoS + cluster reserved-core policy in `k0s.yaml`. No explicit `cpuset` on the pod. |
| **D7** | Compose retirement → rename to `*.archived.yaml` | After k0s deployment is green, rename `development.docker-compose.yaml` → `development.docker-compose.archived.yaml` to discourage `docker compose up` while preserving the file for reference. |

No remaining open questions for this scope. (The original "host-path
option" question is superseded by D2 + D3.)

---

## 5. Rollout plan

Assumes the decisions in §4 and the current `feat/local-registry-mirror`
branch as the base.

### Stage 0 — Build and push the phantom-models image (one-time)

The pod cannot start without an image to mount. Before any manifest
changes, build the first `phantom-models` image from whatever currently
lives at `/root/phantom-models-merged` on mk09 and push it to the local
registry — wrapper script does both:

```bash
cd ~/development/foundation/platformOsDepl/Phantom-OS-KubernetesOptions
sudo python3 scripts/phantom-models/build.py

# Verify
curl -fs http://localhost:5443/v2/phantom-models/tags/list
```

Tag defaults to today's date (`YYYY-MM-DD`); override with `--tag` if
needed. The same tag lands in the mk09 overlay's `images:` block in
Stage 1.

### Stage 1 — Land the manifests on the branch (no cluster change)

1. Create `manifests/base/positronic/configmap.yaml` with base defaults
   (`ROS_DOMAIN_ID: "1"`, `PHANTOM_CMD: ""`).
2. Rewrite `manifests/base/positronic/positronic-control.yaml`:
   - `envFrom: configMapRef: positronic-config` + hardcoded `env:` block
   - `args:` with the conditional `PHANTOM_CMD`-or-sleep-infinity shell
   - `workingDir: /src/workspace`
   - 11 `hostPath` mounts (drop gradle, X11, and `/nix/store` from the
     compose list; drop the host-side models mount in favor of the
     image volume from §3.6a)
   - `image:` volume for `phantom-models`, mounted at `/root/models`
   - `resources: 8 CPU / 16Gi`
3. Update `manifests/base/positronic/kustomization.yaml` to include the
   ConfigMap.
4. Update `manifests/robots/mk09/kustomization.yaml`:
   - Add `images:` entries pinning `localhost:5443/positronic-control`
     and `localhost:5443/phantom-models` to specific tags.
   - mk09 does **not** patch the ConfigMap (per D4); the
     `manifests/robots/mk09/patches/positronic-config.yaml` file is
     left as a placeholder/template for future robots that need overrides.
5. Commit + push to the branch.

### Stage 1.1 — Prerequisite: `image:` volume support in k0s

Before applying §3.6a's manifest, verify the cluster can serve `image:`
volumes:

```bash
sudo k0s version             # need k8s >= 1.31 (alpha) or >= 1.33 (beta)
```

If the `ImageVolume` feature gate is off, enable it (see §3.6a) and
`sudo k0s restart`. If the k0s version is too old to support image
volumes at all, fall back to the initContainer + emptyDir variant
documented as the §3.6a footnote and revisit when k0s is upgraded.

### Stage 2 — Apply to the robot, keep docker-compose side-by-side

1. `git pull --ff-only` on the robot.
2. Scale the existing docker-compose phantom container off OR change
   its `container_name` so both can run side by side briefly (they'll
   compete for ports and shm, but we can test non-overlapping commands).
3. `k0s kubectl apply -k manifests/base/positronic/` (creates ConfigMap
   + updated Deployment).
4. Verify pod reaches `Running 1/1`. Without `PHANTOM_CMD` set, the pod
   runs `sleep infinity` and stays up.
5. `k0s kubectl -n positronic exec -it deploy/positronic-control -- bash` —
   sanity-check mounts, env, cwd, that `colcon build` still works against
   the host-mounted `/src`, and that `/root/models` reflects the contents
   of the `phantom-models` image.

### Stage 3 — Exercise the launch override

1. Patch the ConfigMap with a real `PHANTOM_CMD`:
   ```bash
   k0s kubectl -n positronic patch configmap positronic-config --type=merge \
     -p '{"data":{"PHANTOM_CMD":"ros2 launch srg_localization global_positioning_launch.py"}}'
   k0s kubectl -n positronic rollout restart deploy/positronic-control
   ```
2. `k0s kubectl -n positronic logs -f deploy/positronic-control` — expect ROS
   launch output, not the interactive shell.
3. Revert the ConfigMap to `PHANTOM_CMD: ""` to go back to interactive mode.

### Stage 4 — Stop running docker-compose for phantom and archive the file

Once the k0s pod can do everything the compose container did (interactive
dev + service launches), stop the compose container permanently and
rename the compose file (decision **D7**) so a casual `docker compose up`
can't bring it back accidentally:

```bash
cd ~/development/foundation/imu-policy/positronic_control
docker compose -f docker/development.docker-compose.yaml down phantom

git mv docker/development.docker-compose.yaml \
       docker/development.docker-compose.archived.yaml
git commit -m "docker-compose: archive phantom service after k0s migration"
```

The archived file remains in git as historical reference and as a
double-check on the migrated env / mounts, but its renamed extension
takes it out of the default `docker compose up` discovery path.

### Stage 5 — Merge to main

Once the robot is running positronic-control via k0s happily for a day
or two, merge `feat/local-registry-mirror` to main. ArgoCD then adopts
the Deployment + ConfigMap + image pin.

---

## 6. Out of scope

- Moving the positronic build pipeline into CI (currently robot-local
  `docker build`).
- Moving the **`phantom-models` image build into CI**. The first one
  is built by hand from `/root/phantom-models-merged` per §3.6a;
  rebuild cadence and CI ownership are a separate decision.
- NVIDIA device plugin installation on k0s (blocks dropping `privileged`).
- Replacing hostPath mounts with PersistentVolumes everywhere.
- Migrating the other (commented-out) compose services (dma-video-producer,
  mediamtx, etc.) — dma-video is already under k0s in a separate stack;
  mediamtx can follow the same path if needed.
- Encryption-at-rest for the positronic ConfigMap. It holds no secrets;
  if it grows secrets, they move to a Secret and the etcd-encryption
  conversation from the registry plan (§6 in that doc) applies.

---

## 7. Review checklist

Pre-implementation verification — each box should be checked before
manifests land on the cluster:

- [ ] **D1** verified: nothing on mk09 references `/nix/store` paths
      (ldd / strings sweep on the running phantom binaries).
- [ ] **D2 + D3** prerequisite: `sudo k0s version` reports k8s ≥ 1.31
      and the `ImageVolume` feature gate is enabled (or fallback to
      initContainer + emptyDir is consciously chosen).
- [ ] **D2 + D3** built: first `phantom-models` image built and pushed
      to `localhost:5443/phantom-models:<tag>` per §3.6a.
- [ ] **D4** confirmed: mk09 overlay does not patch `ROS_DOMAIN_ID`;
      ROS systems on the network expect `1`.
- [ ] **D5** confirmed: operator team is comfortable with ConfigMap
      edit + `rollout restart` to flip between interactive and service
      modes.
- [ ] **D6** confirmed: k0s `cpuManagerPolicy: static` is set on the
      worker profile and the reserved-core policy in `k0s.yaml` matches
      expectations for the robot.
- [ ] **D7** confirmed: nothing else in the repo references
      `development.docker-compose.yaml` by that filename (CI, scripts,
      bin/start.sh).
- [ ] Mount drops (gradle, X11, /nix/store) acceptable — no silent loss
      of functionality.
- [ ] Resource limits (8 CPU, 16Gi) acceptable as starting point.
- [ ] Staged rollout acceptable — docker-compose stays running while
      k0s pod comes up alongside.

---

*Review session 2026-04-25: see [decision log](../../../.claude/plans/this-is-no-longer-effervescent-popcorn.md) for the back-and-forth that produced D1–D7.*
