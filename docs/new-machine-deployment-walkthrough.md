# New machine deployment walkthrough

End-to-end recipe for bringing up a fresh robot from a clean OS to a
running policy. The `ak-007/positronic-off` branch in this repo is the
worked example — it is what an operator's per-robot branch looks like
once it is committed and pinned at known-good tags.

The narrative is opinionated: every step says **what to do**, **why
it matters**, and **what "done" looks like** before moving on. Cross
references point at the canonical scripts and design docs in this repo
so this walkthrough doesn't need to re-explain them.

Companion reading:
- [positronic-design.md](positronic-design.md) — why the stack is shaped this way
- [trouble-shooting-guide.md](trouble-shooting-guide.md) — day-to-day commands and recovery
- [dockerhub-creds.md](dockerhub-creds.md) — some more details on how to handle credentials 
- DMA.ethercat `README.md` (sibling repo) — bare-metal EtherCAT master

---

## 0. Prerequisites

- Ubuntu LTS (22.04 / 24.04). Architecture: **amd64** for x86 robots
  (mk09, ak-007), **arm64/aarch64** for Jetson-class robots.
- Root access on the robot.
- A DockerHub account with read access to `foundationbot/*` (private).
- A GitHub fork / branch under `foundationbot/Phantom-OS-KubernetesOptions`
  for this robot — the example is `ak-007/positronic-off`.
- The robot's EtherCAT NIC is identified (e.g. `ecat1`) and the chosen
  RT cores are isolated via GRUB (`isolcpus=...`). See the README's
  "CPU isolation" section.
- A checked-out copy of `DMA.ethercat` with the matching `phantom-NNNN.json`
  config for this robot (e.g. `config/phantom-0009.json`).

---

## 1. Install DMA.ethercat from the .deb and bring up the systemd service

The EtherCAT master runs **bare metal** — never in k0s. Real-time
priority + raw socket + RT cores can't survive a CNI or a container
runtime in the path. Install it first; everything downstream assumes
the motors can be enabled.

### 1.0 Isolate the RT cores via cgroup v2 cpuset (aarch64)

On aarch64 robots (Jetson-class), use the
[`manage_cpusets.sh`](../../DMA/DMA.ethercat/scripts/manage_cpusets.sh)
helper. It carves out an isolated cgroup v2 cpuset partition at boot,
ahead of `docker.service`, `user@.service`, and `systemd-logind.service`,
so nothing else has already claimed those CPUs by the time
`dma-ethercat` starts.

The canonical runbook is
[`DMA.ethercat/docs/CPUSETS_SETUP.md`](../../DMA/DMA.ethercat/docs/CPUSETS_SETUP.md);
the architecture / library reference is `scripts/CPUSETS.md`. What's
below is the fleet-specific application of that runbook — follow the
runbook for the authoritative version.

This replaces the `isolcpus=` GRUB approach the README describes for x86.
`isolcpus=` and cpuset partitions can coexist, but keeping `isolcpus=`
means the isolated CPUs can't be dynamically released — Step 4 below
migrates the cmdline off it.

**Target layout for this fleet** — isolate cores **10–13** (matches
the legacy `isolcpus=10-13` on Thor). The EtherCAT motor controller
runs on **11, 12, 13** (matches `DMA_CPU_AFFINITY=11,12,13` /
`DMA_RT_CPU=11` in step 1.3); core **10** is reserved for the
**whole-body controller (WBC)**. Pinning the WBC explicitly is
preferred but optional — you can also limit the isolation to **11–13**
and leave core 10 in the general housekeeping pool.

#### Step 0 — Write `/etc/cpusets.conf`

The fleet default (single partition, matches `isolcpus=10-13`):

```bash
sudo install -m 0644 /dev/stdin /etc/cpusets.conf <<'EOF'
[ecat]
cpus = 10-13
description = EtherCAT master RT loop (cores 11-13) + WBC (core 10)
EOF
```

Variant A — pin WBC explicitly to its own partition:

```ini
[ecat]
cpus = 11-13
description = EtherCAT master + motor controller RT loop

[wbc]
cpus = 10
description = Whole-body controller
```

Variant B — drop core 10 entirely, isolation limited to 11–13:

```ini
[ecat]
cpus = 11-13
description = EtherCAT master + motor controller RT loop
```

Constraints enforced by `apply`: alphanumeric section names, no
overlapping CPUs across sections, ≥ 2 housekeeping CPUs left over.

#### Step 1 — Apply at runtime

```bash
cd ~/development/foundation/DMA/DMA.ethercat
sudo ./scripts/manage_cpusets.sh apply /etc/cpusets.conf
sudo ./scripts/manage_cpusets.sh verify ecat
sudo ./scripts/manage_cpusets.sh list
```

If `apply` fails citing `docker.slice` (or another sibling slice)
claiming the CPUs, stop the offending service and retry, or skip ahead
to Step 3 — the boot service ordering takes care of it on the next
reboot.

#### Step 2 — Pin the EtherCAT NIC IRQs (interactive)

```bash
sudo ./scripts/manage_cpusets.sh ethercat-rt ecat --nic ecat1
```

This step **prompts** for confirmation when picking the RT core inside
the partition — don't pipe stdin or run under nohup. `--nic` defaults
to `ecat0`; pass the actual interface from `ip -br link`. The script
pins the NIC's IRQs to the chosen core, applies ethtool low-latency
tuning, locks `cpufreq` governor to `performance` on every isolated
core, restricts unbound kernel workqueues to housekeeping cores, and
installs a separate boot service that re-applies the tuning after
reboot or link flap.

#### Step 3 — Install boot persistence

```bash
sudo ./scripts/manage_cpusets.sh install-service /etc/cpusets.conf
sudo ./scripts/manage_cpusets.sh install-affinity-defaults
sudo systemctl daemon-reexec
```

`install-service` orders `cpusets.service` `Before=docker.service
user@.service systemd-logind.service` so those slices can't claim the
isolated CPUs before the partition activates. It deliberately does
**not** chain `install-affinity-defaults` — that step writes
`/etc/systemd/system.conf.d/cpuaffinity.conf` keeping every
systemd-spawned service off the isolated cores by default. The
`daemon-reexec` is required for the affinity drop-in to apply to
services started before this step.

#### Step 4 — Migrate the kernel cmdline (interactive)

```bash
sudo ./scripts/manage_cpusets.sh migrate-cmdline --add-rt-flags
```

Detects bootloader (`/boot/extlinux/extlinux.conf` on Jetson,
`/etc/default/grub` on x86), backs up the current config with a
timestamp, removes `isolcpus=` tokens, and with `--add-rt-flags` adds
`rcu_nocb_poll`, `skew_tick=1`, `irqaffinity=<housekeeping>`.
**Prompts before writing — read the diff first; don't pass `--yes`
on the first run.** On Jetson there's no in-place rollback after
reboot if the new cmdline doesn't come up — recovery requires booting
from recovery media. The backup path is printed by the script.

#### Step 5 — Reboot

```bash
sudo reboot
```

#### Step 6 — Verify after reboot

```bash
systemctl status cpusets.service
journalctl -u cpusets.service -b                 # no "CPUs not exclusive"
sudo ./scripts/manage_cpusets.sh list
sudo ./scripts/manage_cpusets.sh verify
sudo ./scripts/manage_cpusets.sh status

cat /proc/cmdline                                # must NOT contain isolcpus=
                                                  # must contain rcu_nocb_poll, skew_tick=1, irqaffinity=
cat /sys/devices/system/cpu/isolated             # matches your config CPUs
grep ecat1 /proc/interrupts                      # IRQ counts only on the pinned core
```

The `dma-ethercat` unit's `taskset -c ${DMA_CPU_AFFINITY}` will land
its threads on cores 11–13 inside the `ecat` partition. k0s, docker,
and systemd user sessions are confined to the remaining cores.

#### One-shot alternative (single partition, single NIC)

If you only have one partition and one NIC and don't want a config file,
Steps 1 + 2 collapse to:

```bash
sudo ./scripts/manage_cpusets.sh create ecat 10-13 --with-ethercat-rt --nic ecat1
```

Steps 3, 4, 5, 6 still need to run separately.

### 1.1 Get the `.deb`

Two paths. **Pulling from the published Docker image is the recommended
one for a fresh robot** — no source checkout, no build toolchain, no
`dma-common` wheels to resolve. Local-build is for when you're iterating
on the EtherCAT master itself.

#### Option A — Pull from `foundationbot/dma-ethercat` (recommended)

CI publishes per-arch image tags to `foundationbot/dma-ethercat`. Each
image ships a freshly-built `.deb` at
`/usr/local/share/dma/deb/dma-ethercat-*.deb` — pull the tag matching
this robot's architecture.

Tag conventions:
- `…-latest-aarch64` — Jetson / arm64 robots (e.g. ak-007)
- `…-latest-amd64`   — x86 robots
- `main-latest` — multi-arch manifest, lets Docker pick by host platform

Concrete example (aarch64, current branch on FIR-223):

```bash
# Pull (private image — needs the dockerhub login from step 6).
docker pull foundationbot/dma-ethercat:fir-223-ci-build-debs-both-archs-latest-aarch64

# Extract the .deb out of the image. `docker create` makes a stopped
# container without running the entrypoint; `docker cp` then copies the
# file out. No need to actually start the container.
mkdir -p /tmp/dma-deb
cid=$(docker create foundationbot/dma-ethercat:fir-223-ci-build-debs-both-archs-latest-aarch64)
docker cp "$cid":/usr/local/share/dma/deb/. /tmp/dma-deb/
docker rm "$cid"

ls /tmp/dma-deb/
# dma-ethercat-arm64-V-<ver>.deb     (aarch64 image)
# dma-ethercat-amd64-V-<ver>.deb     (amd64 image)
```

For amd64 hosts, swap the tag suffix to `…-latest-amd64`. For a known-good
pinned version, use a timestamped CI tag (e.g.
`fir-223-ci-build-debs-both-archs-20260126T191500-aarch64`) instead of
`-latest-`.

If you only want the binaries (not the `.deb`), the image's entrypoint
also supports `--install <dir>` which drops `dma_main`, `health_monitor`,
helpers, scripts, and configs into the mounted directory — useful for
the bare-binary deployment path the README documents:

```bash
sudo mkdir -p /opt/dma
sudo docker run --rm -v /opt/dma:/opt/dma \
     foundationbot/dma-ethercat:fir-223-ci-build-debs-both-archs-latest-aarch64 \
     --install /opt/dma
```

That path skips the systemd unit and conffile though, so for the
service-managed install you want the `.deb` extraction above.

#### Option B — Build the `.deb` locally

If you've made local changes to `DMA.ethercat`, build a `.deb` from the
checkout. Artefacts live under `build-amd64/` (x86) or `build/` (aarch64);
pattern `dma-ethercat-<arch>-V-<ver>.deb`.

```bash
cd ~/development/foundation/DMA/DMA.ethercat
# (build instructions: see DMA.ethercat README)
ls build-amd64/dma-ethercat-amd64-V-*.deb     # x86
# or
ls build/dma-ethercat-arm64-V-*.deb           # jetson
```

### 1.2 Install

```bash
# From option A (extracted to /tmp/dma-deb)
sudo dpkg -i /tmp/dma-deb/dma-ethercat-*.deb

# Or from option B (local build)
sudo dpkg -i build-amd64/dma-ethercat-amd64-V-*.deb

sudo systemctl daemon-reload
```

`dma-common` is a header-only build-time dependency — no `Depends:` on
the runtime package, so a single `dpkg -i` is sufficient.

The `.deb` ships:
- `/usr/bin/dma_main` — the binary
- `/lib/systemd/system/dma-ethercat.service` — the unit
- `/etc/dma/dma-ethercat.env` — runtime config (a dpkg **conffile**, so
  local edits survive upgrades)
- `/usr/share/dma-ethercat/config/...` — the bundled `phantom-NNNN.json`
  configs

### 1.3 Choose the robot config

Each robot has a `phantom-NNNN.json` describing slave layout, joint
mappings, gear ratios, etc. ak-007's example uses `phantom-0009.json`;
mk09 uses the same; pick the one matching this robot's hardware.

If the bundled config is right, point the env file at the shipped path.
If it isn't (or you want local edits), copy it into `/etc/dma/` so
`dpkg -i` upgrades can't stomp on it:

```bash
sudo cp /usr/share/dma-ethercat/config/phantom-0009.json /etc/dma/phantom-0009.json
sudoedit /etc/dma/dma-ethercat.env
```

Set:

```sh
DMA_CONFIG=/etc/dma/phantom-0009.json
INTERFACE=ecat1                # the EtherCAT NIC, NOT eth0
DMA_CPU_AFFINITY=11,12,13      # taskset syntax; must overlap isolcpus/cpuset
DMA_RT_CPU=11                  # one of the cores in DMA_CPU_AFFINITY
```

`INTERFACE` is the bare NIC name visible to `ip link show`. `DMA_CPU_AFFINITY`
must be a subset of the isolated cores — the `ecat` cpuset partition from
step 1.0 on aarch64 (cores 11–13), or the kernel's `isolcpus=` range on
x86 — so the RT thread isn't fighting general workloads. The unit applies `taskset -c
${DMA_CPU_AFFINITY}` at `ExecStart` (systemd's native `CPUAffinity=` does
not expand env vars from `EnvironmentFile`).

### 1.4 Enable + start

```bash
sudo systemctl enable  dma-ethercat       # come up on every boot
sudo systemctl start   dma-ethercat
sudo systemctl status  dma-ethercat       # expect active (running)
```

The unit grants `CAP_NET_RAW`, `CAP_SYS_NICE`, `CAP_IPC_LOCK` so it
doesn't need to run as root. SCHED_FIFO priority 90 is set via
`CPUSchedulingPolicy=fifo` / `CPUSchedulingPriority=90`.

### 1.5 What "done" looks like

```bash
journalctl -u dma-ethercat -b | grep -E "OP|operational|All slaves"
```

You should see all configured slaves transitioning into the EtherCAT
**OP** (operational) state. PDOs cycling, no `EMCY` storms. If the unit
restarts in a loop, see the DMA.ethercat README's troubleshooting
section — the most common causes are wrong `INTERFACE`, wrong
`DMA_CONFIG`, or `DMA_RT_CPU` not in the isolcpus range.

---

## 2. Get the per-robot branch on the build host

The `ak-007/positronic-off` branch is the example of what a per-robot
branch looks like once it has been pinned to known-good image tags.

```bash
cd ~/development/foundation/platformOsDepl/Phantom-OS-KubernetesOptions
git fetch origin
git checkout ak-007/positronic-off
```

What this branch contains, vs. `main`:

```
gitops/apps/ak-007/phantomos-ak-007.yaml   targetRevision: ak-007/positronic-off
manifests/robots/ak-007/kustomization.yaml  pinned positronic-control + phantom-models tags
```

See the diff: <https://github.com/foundationbot/Phantom-OS-KubernetesOptions/compare/main...ak-007/positronic-off>

The Application is pinned to its own branch (`targetRevision:
ak-007/positronic-off`) and `selfHeal: false` so a freshly-built image
tag landing in the overlay doesn't get clobbered by an out-of-band
ArgoCD reconcile while the operator is still validating it. Once the
image is settled, merge to `main` and re-enable `selfHeal: true`.

For a brand-new robot, fork ak-007's overlay:

```bash
cp -r manifests/robots/ak-007 manifests/robots/<new-robot>
cp -r gitops/apps/ak-007       gitops/apps/<new-robot>
# Edit names, robot label, branch name; commit; push.
```

---

## 3. Build the production positronic-control image (`feat/se-union-receiver`)

The production image needs to be used here and not the development one.

### 3.1 Check out the policy branch

```bash
cd <path to positronic_control>
git fetch origin
git checkout feat/se-union-receiver
git submodule update --init --recursive
```

`feat/se-union-receiver` is the branch carrying the latest DMA IPC integration.

### 3.2 Build the base + production image

The production image is a two-stage build: `phantom-cuda` base, then
`phantom-cuda-production` layer that copies the workspace and runs
`colcon build`.

```bash
cd ~/.../positronic_control

# Base (cu130 on aarch64, cu128 on amd64). Auto-selected by uname -m.
bash bin/build.sh phantom

# Production overlay — copies /src, runs colcon build, sources the workspace.
bash bin/build.sh phantom-production
```

The two functions are `build_phantom` and `build_phantom_production` in
`bin/build.sh`. They tag images as:

```
foundationbot/phantom-cuda:<VERSION>-cu130                 # base (aarch64)
foundationbot/phantom-cuda:<VERSION>-production-cu130      # production (aarch64)
```

`VERSION` is read from the `VERSION` file at the repo root.

### 3.3 Retag for the local registry

The cluster only pulls from `localhost:5443`. Retag the production
image into the local-registry path:

```bash
TAG=0.2.44-production-cu130-flat
docker tag foundationbot/phantom-cuda:0.2.44-production-cu130 \
           localhost:5443/positronic-control:$TAG
```

Push happens in step 5 once the registry is up. You can also use the
one-shot wrapper later:

```bash
bash ~/development/foundation/platformOsDepl/Phantom-OS-KubernetesOptions/scripts/positronic.sh \
     push-image localhost:5443/positronic-control:$TAG
```

---

## 4. Build the phantom-models image

The model weights ship as a separate OCI image so the policy image
stays small and rebuilds don't reship gigabytes of weights. The init
container `load-models` copies `/models/.` from this image into a
shared `emptyDir` that the main container then mounts read-only at
`/root/models`.

Source: [`scripts/phantom-models/build.py`](../scripts/phantom-models/build.py).

### 4.1 Stage the weight tree on disk

The default root is `/root/phantom-models-merged`. Create it (or
override with `--root`) and drop each model directory in as a
top-level entry. Each chosen entry lands at `/models/<entry-name>` in
the image.

### 4.2 Run the build

Three modes, pick one:

```bash
cd ~/.../Phantom-OS-KubernetesOptions

# (a) Interactive — lists top-level entries, asks which to include.
sudo python3 scripts/phantom-models/build.py

# (b) Bundle the whole root.
sudo python3 scripts/phantom-models/build.py --all

# (c) Explicit per-model selection from a YAML manifest.
sudo python3 scripts/phantom-models/build.py --manifest scripts/phantom-models/models.yaml
```

Tag defaults to today's date (`YYYY-MM-DD`); override with `--tag`.
Default registry is `localhost:5443`; override with `--registry`. Use
`--no-push` to build locally without pushing.

The image is `FROM busybox:1.36.1` (not `FROM scratch`) so the init
container has `sh + cp` for the copy fallback — k0s 1.35.3's containerd
has only partial support for KEP-4639 `image:` volumes. See
**Decision D3** in the design doc.

### 4.3 What "done" looks like

```bash
curl -fs http://localhost:5443/v2/phantom-models/tags/list
# {"name":"phantom-models","tags":["2026-04-29"]}
```

Bump the tag in the overlay (step 5.4).

---

## 5. Prime the secondary registry and pin manifest tags

### 5.1 Why a local registry

The robot may lose DockerHub access or you may want to iterate on your local change before pushinig to the git repo. Anything required for a pod to
start must come from the local registry. `containerd`'s `hosts.toml`
routing tries `http://localhost:5443` first and falls through to
`registry-1.docker.io` only on 404. See **§4.2** in the design doc.

The local registry isn't a pull-through proxy — Distribution `registry:2`
goes read-only when `REGISTRY_PROXY_REMOTEURL` is set, which would
block `docker push` of locally-built images. We fill it on a manual /
scheduled basis instead.

### 5.2 Push positronic-control + phantom-models

If the bootstrap script hasn't started the registry yet, do step 7
first and come back. If it has, push:

```bash
cd ~/.../Phantom-OS-KubernetesOptions

docker push localhost:5443/positronic-control:0.2.44-production-cu130-flat
docker push localhost:5443/phantom-models:2026-04-29
```

### 5.3 Prime everything else the cluster pulls

The script normalises image refs into the local-registry path
containerd's hosts.toml expects (`mongo:7` →
`localhost:5443/library/mongo:7`).

```bash
# Fill from the YAML in this repo (recommended for a fresh bring-up).
bash scripts/prime-registry-cache.sh --from-manifests manifests/

# Or from the running cluster (later, after k0s is up).
bash scripts/prime-registry-cache.sh --from-cluster
```

### 5.4 Pin tags in the overlay

Edit `manifests/robots/<robot>/kustomization.yaml`:

```yaml
images:
  - name: localhost:5443/positronic-control
    newTag: 0.2.44-production-cu130-flat
  - name: localhost:5443/phantom-models
    newTag: 2026-04-29
```

Kustomize's `images:` transformer rewrites both `containers:` and
`initContainers:`, so a single entry per repo covers the main pod
*and* the `load-models` init container.

Commit and push to the per-robot branch:

```bash
git add manifests/robots/<robot>/kustomization.yaml
git commit -m "<robot>: bump positronic-control to 0.2.44-production-cu130-flat"
git push origin <robot>/positronic-off
```

### 5.5 Validate

```bash
bash scripts/validate-local-registry.sh
```

---

## 6. DockerHub credentials at `~/.docker/config.json`

Some images are still private (`foundationbot/*` for argus, nimbus,
dma-video, the base `phantom-cuda` images). Both **Docker** (for
pulling-and-priming) and **containerd via the kubelet** (for any
fallthrough pulls) need creds.

### 6.1 Docker login

```bash
docker login -u <dockerhub-user>
# Password / PAT prompt. Use a PAT scoped read-only.
```

This writes `~/.docker/config.json` with an `auths` entry:

```json
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "<base64 user:token>"
    }
  }
}
```

This file is what `prime-registry-cache.sh` and `docker pull` use.

### 6.2 Per-namespace pull secrets (k8s)

The kubelet uses Kubernetes Secrets (`type: docker-registry`), not the
host `~/.docker/config.json`, for its own pulls. Create one per
namespace that needs to pull private images:

```bash
for ns in argus nimbus dma-video positronic; do
  k0s kubectl create secret docker-registry dockerhub-creds \
    --namespace "$ns" \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=<dockerhub-user> \
    --docker-password=<dockerhub-token> \
    --dry-run=client -o yaml | k0s kubectl apply -f -
done
```

Namespaces must exist first — they get created when ArgoCD applies the
overlay (`CreateNamespace=true`). Run this loop after step 8.

---

## 7. Bootstrap the k0s deployment

[`scripts/bootstrap-robot.sh`](../scripts/bootstrap-robot.sh) brings a
fresh machine to a working **k0s + ArgoCD + local-registry** state in
seven phases. Idempotent; re-running on a bootstrapped host detects
existing config and skips destructive steps.

```bash
cd ~/development/foundation/platformOsDepl/Phantom-OS-KubernetesOptions

sudo bash scripts/bootstrap-robot.sh \
     --robot ak-007 \
     --setup-positronic \
     --positronic-image foundationbot/phantom-cuda:0.2.44-production-cu130
```

What the phases do:

| # | Phase           | What                                                                                                       |
|---|-----------------|------------------------------------------------------------------------------------------------------------|
| 1 | preflight       | OS / arch / kernel / disk / sudo / port collisions                                                         |
| 2 | deps            | apt: docker.io, skopeo, python3, curl, jq, git, pciutils, unzip; k0s binary; terraform binary              |
| 3 | host config     | `configure-k0s-containerd-mirror.sh` + `configure-k0s-nvidia-runtime.sh` (if a GPU is detected)            |
| 4 | cluster         | `k0s install controller --single --enable-worker`; `systemctl enable --now k0scontroller`; write kubeconfig |
| 5 | gitops          | `terraform init && terraform apply` — installs ArgoCD via Helm and applies `gitops/root-app.yaml`          |
| 6 | setup-positronic | (optional) Push positronic-control image to local registry, build phantom-models, redeploy the pod         |
| 7 | validate        | `bash scripts/validate-local-registry.sh`                                                                  |

Useful flags:

- `--reset` — tear down any pre-existing k0s cluster before phase 1
  (backs up kubeconfig + tfstate; preserves on-disk hostPath data
  under `/var/lib/k0s-data/`, `/var/lib/registry/`, `/var/lib/recordings/`).
- `--dry-run` — print what each phase would do, change nothing.
- `--skip-deps` / `--skip-host` / `--skip-cluster` / `--skip-gitops` /
  `--skip-validate` — surgical re-runs.

The script installs ArgoCD via the official Helm chart and applies
`gitops/root-app.yaml`, which is the canonical app-of-apps. From there
ArgoCD reconciles `gitops/apps/<robot>/phantomos-<robot>.yaml`, which
points at `manifests/robots/<robot>/` on the per-robot branch.

---

## 8. Get into ArgoCD and watch the apps converge

### 8.1 Get the bootstrap admin password

```bash
k0s kubectl -n argocd get secret argocd-initial-admin-secret \
   -o jsonpath='{.data.password}' | base64 -d ; echo
```

### 8.2 Reach the ArgoCD UI

ArgoCD is exposed via Ingress / NodePort depending on the overlay.
Easiest is a port-forward:

```bash
k0s kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open <https://localhost:8080> and log in as `admin` / the password from
8.1. You should see two Applications:

- `root` — the app-of-apps
- `phantomos-<robot>` — the per-robot stack pinned to the
  `<robot>/positronic-off` branch

### 8.3 CLI status

```bash
# All Applications
k0s kubectl -n argocd get applications

# This robot's app
k0s kubectl -n argocd get application phantomos-ak-007 \
   -o jsonpath='Sync: {.status.sync.status}{"\n"}Health: {.status.health.status}{"\n"}'

# Per-resource breakdown if Sync/Health is mixed
k0s kubectl -n argocd get application phantomos-ak-007 \
   -o jsonpath='{range .status.resources[*]}{.kind}/{.namespace}/{.name}: sync={.status} health={.health.status} {.health.message}{"\n"}{end}'
```

Wait until `Sync: Synced` and `Health: Healthy`. If something's stuck,
[`scripts/diagnose-positronic.sh`](../scripts/diagnose-positronic.sh)
gives a one-shot diagnostic across the registry, the positronic
deployment, PV/PVC binding, runtime class, and image pull state.

Common pod-level checks:

```bash
k0s kubectl get pods -A
k0s kubectl -n positronic describe pod -l app=positronic-control
k0s kubectl -n positronic logs -l app=positronic-control --tail=200
```

---

## 9. Exec into positronic-control and start the policy

The pod's default command is `sleep infinity` — it's a persistent dev
harness. Operators `exec` in and start the policy by hand. (Decision
**D5** in the design doc.)

```bash
cd ~/development/foundation/platformOsDepl/Phantom-OS-KubernetesOptions
bash scripts/positronic.sh exec
```

Inside the container:

```bash
source ~/.bashrc
StartPhantomWalkingIMU2DMA
```

`StartPhantomWalkingIMU2DMA` is an alias baked into the production
image's `~/.bashrc`:

```bash
alias StartPhantomWalkingIMU2DMA="RCUTILS_COLORIZED_OUTPUT=1 \
    ros2 launch phantom_policies dma_policy_launch.py \
    policy_path:=$PHANTOM_MODELS/walking-imu-hard-railing"
```

`$PHANTOM_MODELS` resolves to `/root/models` — the read-only mount the
init container populated from the `phantom-models` image. The launch
file brings up the policy node, the DMA bridge, and the IMU receiver.

You should see ROS2 nodes spinning up and policy inference logs
printing. The DMA bridge connects to the bare-metal `dma-ethercat`
service via shared-memory queues at `/dev/shm/{actuals,desired,errors,...}`
— this is why `hostIPC: true` is set on the pod.

---

## 10. Watch dma-ethercat from outside the pod

The DMA service lives on the host, not in k0s, so its logs are in
journald — not `kubectl logs`.

```bash
journalctl -u dma-ethercat -f                # live tail
journalctl -u dma-ethercat -b                # since last boot
journalctl -u dma-ethercat -n 200 --no-pager # last 200 lines
```

When the policy starts publishing desired joint commands, you should
see the cycle counters incrementing and per-slave PDO traffic in the
EtherCAT logs. EMCY messages mean a slave raised an emergency — see
the `per-device-emcy-error-tables.md` doc in `DMA.ethercat/docs/plans/`.

If you've enabled motor enable + slave recovery flags (the unit does,
by default), the service will attempt to re-OP a slave that drops out.
Persistent re-drops mean a hardware issue (cabling, power, slave
firmware) — debug at the hardware layer, not by restarting the unit
in a loop.

---

## 11. Joystick `X` to start

With the policy running and DMA in OP, the final gate is operator
intent — pressing **X** on the joystick transitions the state machine
from "ready" to "executing" and starts streaming desired commands to
the motors.

If `X` doesn't take effect:

1. Confirm the joystick is enumerated: `ls /dev/input/js*`.
2. Confirm the policy's joystick subscriber is running: in the
   positronic-control pod, `ros2 topic echo /joy` should show events
   when buttons are pressed.
3. Confirm the state machine sees the button: look for "X pressed" /
   state-transition logs in `journalctl -u dma-ethercat -f` and in the
   positronic-control pod logs.
4. If `dma-ethercat` shows desired commands cycling but the robot
   doesn't move: motor-enable bit not asserted on one or more slaves
   — check the EMCY logs and the `enable-motor-enable` flag in the
   unit's `ExecStart`.

At this point the robot is walking under policy control. To stop,
release `X` (or press the configured stop button) and the state
machine drops back to ready.

---

## Appendix: where to look when something goes wrong

| Symptom | First place to look |
|---------|---------------------|
| `dma-ethercat` won't reach OP | `journalctl -u dma-ethercat -b`; verify `INTERFACE`, `DMA_CONFIG`, slave power |
| ArgoCD app stuck `OutOfSync` | `k0s kubectl -n argocd get application phantomos-<robot> -o yaml` events tail |
| Pod `ImagePullBackOff` | `curl http://localhost:5443/v2/_catalog`; re-prime; check `~/.docker/config.json` |
| `load-models` init container fails | `positronic.sh logs --init`; check `phantom-models` tag in overlay |
| `libcuda.so` missing in pod | `runtimeClassName: nvidia` not applied; re-run `configure-k0s-nvidia-runtime.sh` |
| `/dev/shm` queues not appearing | `dma-ethercat` not running, or pod missing `hostIPC: true` |
| Policy starts but X does nothing | `ros2 topic echo /joy`; `/dev/input/js*` permissions |

For deeper recovery (PVC `Lost`, registry full, k0s containerd
restart, etc.) see [trouble-shooting-guide.md](trouble-shooting-guide.md).
