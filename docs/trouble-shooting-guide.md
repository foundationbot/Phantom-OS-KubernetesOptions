# Troubleshooting guide

Operations runbook and troubleshooting guide for the k0s + ArgoCD +
local-registry stack. For the *why* behind any of this, see
[positronic-design.md](positronic-design.md).

Conventions:
- All `kubectl` commands work as `k0s kubectl` on the robot (no separate
  kubectl binary). [`scripts/diagnose-positronic.sh`](../scripts/diagnose-positronic.sh)
  picks whichever is available.
- The local registry lives at `localhost:5443`, hostNetwork bound to
  `127.0.0.1`.
- Tags here are illustrative — real ones live in
  [`manifests/robots/<robot>/kustomization.yaml`](../manifests/robots/).
- `positronic.sh` auto-detects the robot from hostname (must match a
  directory under `manifests/robots/`). Pass `--robot <name>` to
  override. If neither works, the script prompts interactively.

---

## Quick reference (`positronic.sh`)

Most day-to-day operations are wrapped by
[`scripts/positronic.sh`](../scripts/positronic.sh):

```bash
positronic.sh status                       # pod state, QoS, PHANTOM_CMD, PID 1
positronic.sh logs -f                      # follow container logs
positronic.sh logs --previous              # logs from the last crashed instance
positronic.sh logs --init                  # logs from the load-models init container
positronic.sh exec                         # bash into the running container
positronic.sh exec -- ros2 topic list      # run a one-off command in the pod
positronic.sh gpu-test                     # PyTorch CUDA matmul sanity check
positronic.sh push-image <img>:<tag>       # tag + push + bump overlay + redeploy
positronic.sh push-image <img> --no-redeploy  # push only, redeploy later
positronic.sh redeploy                     # apply overlay + bounce the pod
positronic.sh set-cmd <command...>         # set PHANTOM_CMD + rollout restart
positronic.sh clear-cmd                    # clear PHANTOM_CMD (back to sleep infinity)
positronic.sh track-branch [<branch>]      # point ArgoCD at a feature branch
positronic.sh argo-pause                   # disable selfHeal for manual kubectl apply
positronic.sh argo-resume                  # re-enable selfHeal
positronic.sh teardown -y                  # delete deployment + configmap + namespace
```

All commands accept `--robot <name>` and `--dry-run` as global flags.

---

## Build + push positronic-control

The image source lives in
`~/development/foundation/imu-policy/positronic_control/docker/`. Pick a
Dockerfile (currently `phantom-cuda` for the aarch64 jazzy build), tag
it for the local registry, and push.

```bash
cd ~/development/foundation/imu-policy/positronic_control
TAG=$(git rev-parse --short HEAD)
docker build -f docker/phantom-cuda.Dockerfile -t localhost:5443/positronic-control:$TAG .
docker push localhost:5443/positronic-control:$TAG
```

Quick retag of an existing upstream image (current setup ships
`foundationbot/phantom-cuda:0.2.44-cu130` retagged):

```bash
docker pull foundationbot/phantom-cuda:0.2.44-cu130
docker tag  foundationbot/phantom-cuda:0.2.44-cu130 localhost:5443/positronic-control:0.2.44-cu130
docker push localhost:5443/positronic-control:0.2.44-cu130
```

Verify the tag landed:

```bash
curl -fs http://localhost:5443/v2/positronic-control/tags/list
```

### One-shot: push + bump overlay + redeploy

[`scripts/positronic.sh push-image`](../scripts/positronic.sh) folds the
three steps (tag for local registry, `docker push`, bump `newTag` in the
overlay, redeploy) into one. Use it after `docker build` to put a fresh
image on the cluster without hand-editing YAML:

```bash
# Build with the local-registry tag straight away, then push + redeploy.
docker build -f docker/phantom-cuda.Dockerfile \
  -t positronic-control:$TAG .
bash scripts/positronic.sh push-image positronic-control:$TAG

# Skip the rollout (e.g. you want to commit the kustomization change first).
bash scripts/positronic.sh push-image positronic-control:$TAG --no-redeploy

# Override the tag pushed to the registry / written into the overlay.
bash scripts/positronic.sh push-image foundationbot/phantom-cuda:0.2.45-cu130 \
  --tag 0.2.45-cu130
```

The overlay's `localhost:5443/positronic-control` `images:` entry must
already exist — the wrapper updates it in place but won't add a new
entry. `--dry-run` prints every docker + YAML edit it would do.

---

## Build + push phantom-models

Interactive path — prompts for a root dir, lists top-level entries with
sizes, asks which to include. Tag defaults to today's date.

```bash
sudo python3 scripts/phantom-models/build.py
```

Whole-tree variant (no menu, `--root` overrides the default
`/root/phantom-models-merged`):

```bash
sudo python3 scripts/phantom-models/build.py --all
sudo python3 scripts/phantom-models/build.py --all --root /some/other/dir --tag 2026-04-25
```

Curated YAML manifest variant (see
[`scripts/phantom-models/models.example.yaml`](../scripts/phantom-models/models.example.yaml)):

```bash
sudo python3 scripts/phantom-models/build.py \
  --manifest scripts/phantom-models/models.example.yaml \
  --tag 2026-04-25
```

Verify:

```bash
curl -fs http://localhost:5443/v2/phantom-models/tags/list
```

---

## Bump tags in the per-robot overlay

Edit
[`manifests/robots/<robot>/kustomization.yaml`](../manifests/robots/)
under `images:`:

```yaml
images:
  - name: localhost:5443/positronic-control
    newTag: <new-tag>
  - name: localhost:5443/phantom-models
    newTag: <new-date-or-tag>
```

Kustomize's `images:` transformer rewrites both the main container and
the `load-models` initContainer in one shot (both reference
`localhost:5443/phantom-models` / `localhost:5443/positronic-control`).
Then commit + push the YAML.

For positronic-control specifically, `scripts/positronic.sh push-image`
(see ["One-shot: push + bump overlay + redeploy"](#one-shot-push--bump-overlay--redeploy))
does the bump for you as part of pushing the image.

---

## Deploy / re-deploy

### Manual (pre-merge / branch work)

Apply by hand from the branch:

```bash
sudo k0s kubectl apply -k manifests/robots/<robot>/
sudo k0s kubectl -n positronic rollout restart deploy/positronic-control
sudo k0s kubectl -n positronic get pod -l app=positronic-control -w
```

Note that with `selfHeal: true` on the robot's ArgoCD app, ArgoCD will
revert this manual apply within seconds — see
["Test a feature branch end-to-end via ArgoCD"](#test-a-feature-branch-end-to-end-via-argocd)
or ["Pause selfHeal for ad-hoc kubectl apply"](#pause-selfheal-for-ad-hoc-kubectl-apply)
below for the two ways to actually iterate against the live cluster
without merging first.

Wrapper that does the apply + bounce + watch:

```bash
APPLY=1 bash scripts/diagnose-positronic.sh
```

### Test a feature branch end-to-end via ArgoCD

The cluster runs an app-of-apps: a `root` Application reads
`gitops/apps/<robot>/` and creates the per-robot child Application
(e.g. `phantomos-ak-007`). Both the root and child app are pinned to
`main` with `selfHeal: true`.

To pull a whole feature branch through ArgoCD without merging, point
both at the branch. After committing manifest changes:

```bash
# uses the current local git branch by default
bash scripts/positronic.sh track-branch

# or pass a branch explicitly
bash scripts/positronic.sh track-branch feat/my-fix
```

What the wrapper does:
1. Edits `targetRevision:` in the robot's app manifest
   (`gitops/apps/<robot>/phantomos-<robot>.yaml`) to `<branch>`.
2. Commits + pushes that one-line change to the current local branch.
3. Patches the live `root` Application's `spec.source.targetRevision`
   in-cluster.

ArgoCD reconciles within ~3 min. Trigger it now:

```bash
sudo k0s kubectl -n argocd annotate app root \
  argocd.argoproj.io/refresh=hard --overwrite
```

When the test passes, merge to main and flip back:

```bash
bash scripts/positronic.sh track-branch main
```

Notes:
- Any uncommitted changes under `manifests/` aren't on the branch yet —
  commit + push them before ArgoCD reconciles, or it will pull the
  previous tree.
- `track-branch` only commits the gitops Application file; your image-tag
  bumps from `push-image` are separate commits.
- The child app's `targetRevision` must also point at your branch,
  otherwise ArgoCD reads the kustomization from `main` regardless of
  where `root` points. `track-branch` handles both.

### Pause selfHeal for ad-hoc kubectl apply

If you'd rather iterate locally without committing, disable ArgoCD's
selfHeal on the robot's app. Auto-sync stays on (so any new git change
still applies); cluster drift just isn't reverted:

```bash
bash scripts/positronic.sh argo-pause
sudo k0s kubectl apply -k manifests/robots/<robot>/      # sticks
sudo k0s kubectl -n positronic rollout restart \
  deploy/positronic-control
# ... iterate, kubectl apply again, etc ...
bash scripts/positronic.sh argo-resume                   # back to GitOps
```

Drawback: selfHeal is off until you resume — drift in *any* resource
under the robot's app (not just positronic-control) won't be corrected.
Prefer `track-branch` for anything beyond a quick poke.

### Via ArgoCD (post-merge)

ArgoCD's auto-sync (`prune: true`, `selfHeal: true`) reconciles within
~3 min. Force a sync now:

```bash
# or via kubectl annotation
sudo k0s kubectl -n argocd annotate app phantomos-<robot> \
  argocd.argoproj.io/refresh=hard --overwrite
```

Watch reconciliation:

```bash
sudo k0s kubectl -n argocd get app phantomos-<robot> -w
```

---

## Sanity checks

### Pod status, QoS, restart count

```bash
sudo k0s kubectl -n positronic get pod -l app=positronic-control -o wide
sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{.items[0].status.qosClass}{"\n"}'   # expect: Guaranteed
sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}{"\n"}'
```

### Inside-pod GPU test

```bash
POD=$(sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{.items[0].metadata.name}')

sudo k0s kubectl -n positronic exec -it "$POD" -- nvidia-smi
```

PyTorch one-liner that exercises libcuda + a real matmul:

```bash
sudo k0s kubectl -n positronic exec -it "$POD" -- python3 -c '
import torch
print("cuda available:", torch.cuda.is_available())
print("device:", torch.cuda.get_device_name(0))
a = torch.randn(2048, 2048, device="cuda")
b = torch.randn(2048, 2048, device="cuda")
torch.cuda.synchronize()
print("matmul:", (a @ b).sum().item())
'
```

If `nvidia-smi` works but PyTorch says `NVIDIA Driver was not detected`,
the pod almost certainly missed `runtimeClassName: nvidia` — check with
`kubectl get pod -o yaml | grep runtimeClassName`.

### Mounts + env

```bash
sudo k0s kubectl -n positronic exec -it "$POD" -- ls /root/models
sudo k0s kubectl -n positronic exec -it "$POD" -- ls /src
sudo k0s kubectl -n positronic exec -it "$POD" -- env \
  | grep -E '^(PHANTOM_|ROS_|HF_|TORCH_|RMW_)'
```

`/root/models` should reflect the contents of the phantom-models image.
`/src` should be the host's positronic_control checkout (bind mount).

---

## PHANTOM_CMD toggle

Empty `PHANTOM_CMD` → `sleep infinity` (interactive dev). Populated →
the pod execs `bash -c "$PHANTOM_CMD"` after sourcing the ROS overlays.
Decision **D5** in the migration plan.

### Flip into service mode

```bash
sudo k0s kubectl -n positronic patch configmap positronic-config --type=merge \
  -p '{"data":{"PHANTOM_CMD":"ros2 launch srg_localization global_positioning_launch.py"}}'
sudo k0s kubectl -n positronic rollout restart deploy/positronic-control
sudo k0s kubectl -n positronic logs -f deploy/positronic-control
```

### Flip back to dev mode

```bash
sudo k0s kubectl -n positronic patch configmap positronic-config --type=merge \
  -p '{"data":{"PHANTOM_CMD":""}}'
sudo k0s kubectl -n positronic rollout restart deploy/positronic-control
```

### Five-layer "what's actually running?" check

When the toggle seems not to have taken effect, walk these in order —
each one rules out a different lag.

```bash
# 1. ConfigMap value (source of truth)
sudo k0s kubectl -n positronic get cm positronic-config \
  -o jsonpath='{.data.PHANTOM_CMD}{"\n"}'

# 2. Env var inside the pod (envFrom resolution at pod start)
sudo k0s kubectl -n positronic exec deploy/positronic-control -- \
  printenv PHANTOM_CMD

# 3. PID 1 — what the kernel actually launched
sudo k0s kubectl -n positronic exec deploy/positronic-control -- \
  ps -p 1 -o pid,cmd

# 4. Logs since the last restart
sudo k0s kubectl -n positronic logs deploy/positronic-control --tail 50

# 5. Pod age vs ConfigMap resourceVersion (did rollout actually re-roll?)
sudo k0s kubectl -n positronic get cm positronic-config \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}'
sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.startTime}{"\n"}{end}'
```

If layer 1 is updated but layer 2 still shows the old value, the pod
hasn't been restarted yet — `envFrom` only resolves at pod start. If
layer 2 is correct but layer 3 is `sleep infinity`, the new pod
predates the ConfigMap edit; rollout restart again.

---

## Diagnose problems

Read-only diagnostic — pod status, registry inventory, rendered
overlay's image lines, PLACEHOLDER survival check, and a suggested next
step:

```bash
bash scripts/diagnose-positronic.sh
```

Same diagnostic plus apply the overlay and watch the pod come up:

```bash
APPLY=1 bash scripts/diagnose-positronic.sh
```

### Common failures

**`ImagePullBackOff` on any pod** — three common causes:

1. **Image not in the local registry** (for locally-pushed images like
   `positronic-control` or `phantom-models`). Verify:

   ```bash
   curl -fs http://localhost:5443/v2/_catalog
   curl -fs http://localhost:5443/v2/<repo>/tags/list
   ```

2. **Missing `dockerhub-creds` secret** (for images pulled from
   DockerHub). Each namespace that pulls private `foundationbot/*`
   images needs its own copy of the pull secret:

   ```bash
   # Check if the secret exists
   sudo k0s kubectl -n <namespace> get secret dockerhub-creds

   # Create it if missing
   sudo k0s kubectl -n <namespace> create secret docker-registry dockerhub-creds \
     --docker-server=https://index.docker.io/v1/ \
     --docker-username=<username> \
     --docker-password=<token>

   # Then delete the failing pods so they restart with the secret
   sudo k0s kubectl -n <namespace> delete pods --all
   ```

   Namespaces that need this: `argus`, `nimbus`, `dma-video`, `phantom`
   — any namespace with `imagePullSecrets: [{name: dockerhub-creds}]`
   in its manifests.

3. **Image priming** — for offline/faster pulls, prime the local
   registry so containerd tries `localhost:5443` first:

   ```bash
   sudo bash scripts/prime-registry-cache.sh \
     foundationbot/some-image:tag \
     foundationbot/other-image:tag
   ```

**`ImagePullBackOff` on `positronic-control` or `phantom-models`
specifically** — the tag in
`manifests/robots/<robot>/kustomization.yaml` doesn't exist in the
registry. Verify with:

```bash
curl -fs http://localhost:5443/v2/_catalog
curl -fs http://localhost:5443/v2/positronic-control/tags/list
curl -fs http://localhost:5443/v2/phantom-models/tags/list
```

If a tag is missing, build + push it (sections above), then bounce the
pod. Note that `push-image` only handles `positronic-control` — you
must build `phantom-models` separately via
`sudo python3 scripts/phantom-models/build.py` and bump its `newTag`
in the kustomization by hand (or use `--tag` to match the existing tag).

**`CreateContainerError` with cgroup mismatch** —
`expected cgroupsPath to be of format slice:prefix:name`. Means the
nvidia containerd runtime config has `SystemdCgroup = true` while
kubelet is on cgroupfs. The fix is in
[`scripts/configure-k0s-nvidia-runtime.sh`](../scripts/configure-k0s-nvidia-runtime.sh)
(don't set `SystemdCgroup`); if the file was edited by hand, re-run the
script and `sudo systemctl restart k0scontroller`.

**`CrashLoopBackOff` immediately on launch** — the pod ran
`PHANTOM_CMD` and the launch failed. Check logs:

```bash
sudo k0s kubectl -n positronic logs deploy/positronic-control --previous --tail 100
```

If the launch is broken, flip back to dev mode (clear `PHANTOM_CMD`)
and exec in to debug.

**Pod stuck `Pending` "0/1 nodes are available: ... Insufficient cpu"** —
8 vCPU / 16Gi requested. CPU manager has reserved cores excluded from
the allocatable pool; if the host doesn't have 8 free, edit
`resources.requests.cpu` in
[`manifests/base/positronic/positronic-control.yaml`](../manifests/base/positronic/positronic-control.yaml)
or shrink the reserved pool in `k0s.yaml`.

**DaemonSet pods show `DESIRED: 0`** — the DaemonSet has a
`nodeSelector` (e.g. `foundation.bot/robot=true`) and no node has that
label. Check and fix:

```bash
# See what labels the node has
sudo k0s kubectl get node <node> --show-labels

# Add the missing label
sudo k0s kubectl label node <node> foundation.bot/robot=true
```

The DaemonSet controller picks up the label change immediately and
schedules pods on matching nodes.

**`NVIDIA Driver was not detected`** — pod started without the nvidia
runtime. Verify:

```bash
sudo k0s kubectl get runtimeclass nvidia
sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{.items[0].spec.runtimeClassName}{"\n"}'   # expect: nvidia
```

If RuntimeClass is missing, re-apply the overlay
(`manifests/base/runtime-classes/` is included). If the nvidia runtime
isn't registered on the host, run
[`scripts/configure-k0s-nvidia-runtime.sh`](../scripts/configure-k0s-nvidia-runtime.sh).

---

## Registry operations

### Prime the cache from manifests / cluster / explicit list

```bash
# from a directory of YAML
sudo bash scripts/prime-registry-cache.sh --from-manifests manifests/

# from the running cluster (every image referenced by a pod)
sudo bash scripts/prime-registry-cache.sh --from-cluster

# from a file (one image per line, # comments OK)
sudo bash scripts/prime-registry-cache.sh --from-file images.txt

# explicit list
sudo bash scripts/prime-registry-cache.sh \
  foundationbot/argus.auth:qa foundationbot/argus.gateway:qa
```

Requires `docker login` for private foundationbot/* images.

### Inspect what's in the registry

```bash
curl -fs http://localhost:5443/v2/_catalog
curl -fs http://localhost:5443/v2/<repo>/tags/list
```

### Prune stale tags + reclaim disk

The local Distribution registry has its delete API enabled
(`REGISTRY_STORAGE_DELETE_ENABLED=true` in
[`manifests/base/registry/registry.yaml`](../manifests/base/registry/registry.yaml)).
Use [`scripts/prune-registry-tags.sh`](../scripts/prune-registry-tags.sh):

```bash
# Just see what's there
bash scripts/prune-registry-tags.sh --list

# Tags in the registry that no Pod/Deployment/StatefulSet/DaemonSet
# references (image-ref normalization handles both
# localhost:5443/foo:bar and bare foundationbot/foo:bar forms).
bash scripts/prune-registry-tags.sh --orphans

# Remove specific tags (chains a garbage-collect after).
sudo bash scripts/prune-registry-tags.sh \
  --rm positronic-control:0.2.43-cu130 phantom-models:2026-04-15 \
  --gc

# Or in one shot — delete every orphan + reclaim disk, no prompts
sudo bash scripts/prune-registry-tags.sh --rm-orphans --gc -y

# Just GC (e.g. after manual deletes)
sudo bash scripts/prune-registry-tags.sh --gc

# Dry run (works for any subcommand)
sudo bash scripts/prune-registry-tags.sh --rm-orphans --dry-run
```

How it works under the hood:
- `--rm` does the standard two-step Distribution v2 delete:
  `HEAD /v2/<repo>/manifests/<tag>` to resolve the digest, then
  `DELETE /v2/<repo>/manifests/<digest>`. That removes the tag pointer
  but leaves blob bytes on disk.
- `--gc` runs `registry garbage-collect --delete-untagged` inside the
  registry pod, which walks every reachable manifest and deletes the
  blobs nothing references. This is what actually frees space at
  `/var/lib/registry`.
- `--orphans` excludes ReplicaSet history on purpose — Kubernetes keeps
  rolled-back ReplicaSets at `replicas=0` and they'd otherwise pin
  every recent tag as "in use." Use explicit `--rm <tag>` if you do
  want to preserve a rollback waypoint.

### Validate the whole stack (13 layered checks)

```bash
sudo bash scripts/validate-local-registry.sh
```

Exit code = number of failed checks.

### Resize the registry PVC

The registry uses a hostPath PV at `/var/lib/registry` declared in
[`manifests/base/registry/registry.yaml`](../manifests/base/registry/registry.yaml).
hostPath PVs aren't dynamically resizable — the recreate dance:

```bash
# 1. scale the registry deployment to 0
sudo k0s kubectl -n registry scale deploy/k0s-registry --replicas=0

# 2. edit capacity in registry.yaml (PV + PVC stanzas) and commit

# 3. delete the PVC and PV (data on disk at /var/lib/registry stays — Retain)
sudo k0s kubectl -n registry delete pvc k0s-registry-pvc
sudo k0s kubectl delete pv k0s-registry-pv

# 4. re-apply the overlay
sudo k0s kubectl apply -k manifests/robots/<robot>/

# 5. scale back up
sudo k0s kubectl -n registry scale deploy/k0s-registry --replicas=1
```

The Retain reclaim policy means the `/var/lib/registry` directory is
never deleted by k8s — only the PV/PVC objects are recreated to match
the new size declaration.

---

## ArgoCD

### Admin password

```bash
sudo k0s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Username: `admin`.

### Orphaned pods after switching robot apps

If you switch from one per-robot ArgoCD app to another (e.g.
`phantomos-mk09` → `phantomos-ak-007`), the old app's finalizer
deletes resources it managed — but pods in namespaces that the *new*
app doesn't include may linger. Delete orphaned namespaces manually:

```bash
sudo k0s kubectl delete namespace <orphaned-ns>
```

### Full cluster status

```bash
sudo k0s status                    # k0s health
sudo k0s kubectl get pods -A       # all pods across all namespaces
sudo k0s kubectl -n argocd get app # ArgoCD app sync status
```

---

## Tear down and redeploy from scratch

```bash
sudo bash scripts/bootstrap-robot.sh --robot <name> --reset
```

`--reset` tears down the existing k0s cluster, backs up kubeconfig and
terraform state, then runs the full bootstrap. On-disk data at
`/var/lib/k0s-data/`, `/var/lib/registry/`, and `/var/lib/recordings/`
is preserved.

To also push the positronic images during bootstrap:

```bash
sudo bash scripts/bootstrap-robot.sh --robot <name> --reset \
  --setup-positronic --positronic-image foundationbot/phantom-cuda:0.2.44-production-cu130
```

After a reset, remember to recreate any `dockerhub-creds` secrets in
namespaces that pull from DockerHub and re-label the node if DaemonSets
require it (see [Common failures](#common-failures)).

---

## One-time bootstrap (new robot)

Single-command path:

```bash
git clone https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git
cd Phantom-OS-KubernetesOptions
sudo bash scripts/bootstrap-robot.sh --robot <name>      # ak-007, mk09, ...
docker login                                              # for private foundationbot/* images
sudo bash scripts/prime-registry-cache.sh --from-manifests manifests/
```

`bootstrap-robot.sh` orchestrates six phases (preflight, deps, host
config, cluster + kubeconfig, gitops via terraform, validate) and is
idempotent — re-running on a bootstrapped host detects existing config
and prints `SKIP` for what's already done. Useful flags: `--dry-run`
(print plan, change nothing), `--skip-deps` / `--skip-host` /
`--skip-cluster` / `--skip-gitops` / `--skip-validate` to slice phases,
`--skip-nvidia` to override GPU autodetect.

Image priming is the separate step because it needs DockerHub creds.

**Want to disable a base workload (argus, dma-video, …) on this robot
before bringing it up?** Edit
[`manifests/robots/<robot>/kustomization.yaml`](../manifests/robots/)
and remove the relevant `../../base/<name>` line from the `resources:`
block, then commit + push **before** the bootstrap script reaches phase
5. ArgoCD reads the overlay from git; if it isn't listed, it never gets
deployed.

Manual equivalent (what bootstrap-robot.sh runs internally):

```bash
git pull
sudo bash scripts/configure-k0s-containerd-mirror.sh
sudo bash scripts/configure-k0s-nvidia-runtime.sh
sudo k0s install controller --single --enable-worker
sudo systemctl enable --now k0scontroller
sudo k0s kubeconfig admin > /root/.kube/config && sudo chmod 600 /root/.kube/config
cd terraform && terraform init && terraform apply
docker login                                                    # for private foundationbot/* pulls
sudo bash scripts/prime-registry-cache.sh --from-manifests manifests/
sudo bash scripts/validate-local-registry.sh
```
