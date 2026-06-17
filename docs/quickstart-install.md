# Quick start — install Phantom-OS on a robot

> **CONFIDENTIAL.** This document and any corresponding documents shared
> in this drive contain highly sensitive confidential information of
> Foundation, including proprietary technical information that is
> strictly restricted. Please handle in accordance with the NDA, do not
> forward, and limit access to specifically authorized individuals only.

Six steps to bring up a fresh robot from clean Ubuntu to a fully
running cluster, starting from the three artifacts your build host
produced (see `docs/quickstart-build.md`).

Tested on `aarch64` and `amd64`. Sudo throughout.

---

## Before you start

A few minutes of system prep saves a lot of debugging later. Do these
**before** installing anything.

### Pin a static IP (strongly recommended)

The cluster API server, ArgoCD UI, and operator UI all bind to the
robot's network address. If that address changes after install (DHCP
lease renewal, network move, reboot onto a different access point),
those services need to be reconfigured. Set a static IP — or a DHCP
reservation on your router — before running the installer.

On Ubuntu 24.04:

```bash
sudoedit /etc/netplan/01-static.yaml   # pick a free IP on your LAN
sudo netplan apply
ip -4 addr show | grep inet            # verify
```

### System requirements

- **Ubuntu 24.04** with root access (`sudo`).
- **About 50 GB free** on `/` (cluster runtime + container images).
- **Network for the first install** — the k0s cluster runtime binary
  is downloaded from the internet during bootstrap. Subsequent
  reconciles do not need internet (RFC 0006 — Argo tracks the local
  `/opt/.../.git/`).
- **Standard system tools** — already on Ubuntu by default; `apt` pulls
  any missing ones automatically when the control-plane `.deb` installs:
  `python3`, `bash` (≥ 4), `curl`, `jq`, `git`, `unzip`, `tar`, `zstd`.

### Optional: Tailscale (remote access)

Tailscale is a hosted VPN for secure remote access to the robot's
services from outside the local network. **Optional** — skip if you
only need local access.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

The setup wizard will let you use either a Tailscale URL or a LAN IP
for the AI PC pairing.

---

## What you'll need

Three files transferred to the robot (scp from the build host). The
commands below assume you `cd` to wherever they landed (e.g. `~/`
or `~/Downloads/`) before running the install:

| File | Purpose |
|---|---|
| `phantomos-k0s-<version>-all.deb` | Control plane: scripts + manifests + embedded git repo |
| `phantomos-k0s-images-<version>-<arch>.deb` | Image bundle metadata (small) |
| `phantomos-k0s-images-<version>-<arch>.tar.zst` | Image data bundle (multi-GB) |

The `<version>` strings on all three must match. The `<arch>` on the
last two must match. The install wrapper checks and refuses to proceed
on a mismatch.

About 30 minutes of operator attention. The setup wizard asks roughly
15 questions; most have sensible defaults — press Enter to accept.

---

## Setup steps

### 1. Install the control-plane `.deb`

```bash
sudo dpkg -i phantomos-k0s-*-all.deb
```

Drops scripts + manifests + a git repository under
`/opt/Phantom-OS-KubernetesOptions/`. ArgoCD will track this local
repo via `file://` once the cluster is up (RFC 0006).

### 2. Install the image bundle

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh ./
```

The wrapper:

- Auto-discovers the matching `.deb` + `.tar.zst` pair in the directory
  you pointed at (here `./` — the current working directory).
- Verifies that filename stems agree (same version + arch).
- Verifies that the bundle's declared arch matches the host's
  `dpkg --print-architecture`.
- Extracts the sidecar (~30-90 sec depending on disk speed; 15-20 GB
  of image tarballs land under `/var/lib/k0s/images/`).
- Runs `dpkg -i` on the small image `.deb`.
- The `.deb`'s postinst then verifies every tarball the bundle manifest
  references is on disk, and imports each into containerd's k8s.io
  namespace (when k0s is already running) or defers to next k0s start
  (clean first-bringup case).

If you want explicit args instead of auto-discovery:

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh \
  ./phantomos-k0s-images-<v>-<arch>.deb \
  ./phantomos-k0s-images-<v>-<arch>.tar.zst
```

### 3. Run the configure wizard

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/configure-host.sh
```

The wizard walks `/etc/phantomos/host-config.yaml`. Press Enter to
accept any default. Things you'll be asked:

| Prompt | What to answer |
|---|---|
| **robot** | DNS-safe name, e.g. `mk09` |
| **AI PC pairing** | Either type a Tailscale URL (`http://100.x.y.z:5000`) or answer `y` to auto-detect from the default-gateway interface |
| **gitSource** | Press Enter for `local` — ArgoCD tracks `/opt/.../.git/` via `file://` (air-gapped friendly, atomic per-`.deb` updates). Choose `remote` only if your ops flow pushes hot-fixes via `git push` to GitHub |
| **targetRevision** | Skipped automatically when `gitSource: local` (bootstrap pins to the local commit SHA). Asked when `remote`; default is `main` |
| **production mode** | `n` for dev/debug machines (no auto-revert of `kubectl edit`s); `y` for production |
| **stack toggles** | Press Enter to accept defaults: `core` (always on), `operator` (on) |
| **image overrides** | Press Enter to accept. The wizard's `--auto-images` mode reads the bundle manifest and fills positronic-control, phantom-models, operator-ui, and dma-ethercat with the right refs. You'll see a "Defaults from bundle:" preview before any prompts fire |
| **CPU isolation** | `y` and pick the EtherCAT NIC for production robots. `n` on dev hosts without EtherCAT hardware — sets `cpuIsolation.enabled: false` and skips phases 7/8/9 cleanly |
| **deployment mounts** (control runtime) | `production` preset (4 standard mounts) for normal robots |
| **deployment mounts** (api server) | `n` unless you have on-host project trees to expose |

When the wizard finishes it offers to chain into `bootstrap-robot.sh`.
Answer **y** to chain straight into step 4.

### 4. Bootstrap the cluster

If you didn't auto-chain from the wizard:

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh
```

Bootstrap runs ~15 phases. Two prompts during the run:

- **CPU isolation** (only when you said `y` in step 3): partition CPUs,
  partition name, NIC interface, NIC IRQ core, realtime loop core,
  systemd CPUAffinity drop-in. Defaults match most setups.
- **Realtime hardware config** (phase 12, only when CPU isolation is
  enabled): a numbered list of JSON configs. Pick the one matching the
  robot's hardware.

And one mandatory prompt:

- **ArgoCD admin password** — pick something memorable.

Total bootstrap time: ~30 minutes on a fresh install (mostly bound by
k0s install + ArgoCD helm chart + initial pod rolls).

### 5. Confirm everything's running

```bash
sudo k0s kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,IMAGES:.spec.containers[*].image'
```

Expect about 30 pods across 7 namespaces. `STATUS` should be `Running`
for almost all (or `Completed` for one-shot Jobs). Healthy namespaces:

| Namespace | What it does |
|---|---|
| `argocd` | GitOps controller |
| `argus` | Operator user-interface stack |
| `dma-video` | Video pipeline |
| `nimbus` | Episode / data storage |
| `phantom` | On-robot agents |
| `positronic` | Control runtime |
| `kube-flannel`, `kube-system` | Kubernetes plumbing |

The positronic-control pod starts in **dev mode (sleep-infinity
entrypoint)**. To run a policy on it, see
`docs/quickstart-positronic-policy.md`.

Common-and-expected failures:

- **No NVIDIA hardware**: positronic-control stays Init or
  CrashLoopBackOff (no `nvidia` runtime). Environmental, not a deploy
  bug.
- **No OAK cameras**: dma-video producer/viewer exit cleanly and
  Kubernetes restarts them indefinitely → CrashLoopBackOff. Also
  environmental.

### 6. Access the ArgoCD UI

```bash
# print the admin password you set in step 4
sudo k0s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

Browse to `https://<robot-ip>:30443` and log in as `admin`. From here
every workload is git-driven — but unlike traditional GitOps, the
git source is the `.deb`'s local `/opt/.../.git/`. To deploy a new
revision, build a new `.deb` (with manifest changes) and `dpkg -i` it;
ArgoCD picks up the new commit SHA within seconds.

---

## About the dma-ethercat realtime service

Bootstrap's phase 12 installs **dma-ethercat**, the realtime motor
control service the robot needs to talk to its EtherCAT slaves (motor
drives, IMUs, sensors). Skip this section if you set
`cpuIsolation.enabled: false` in host-config — the whole subsystem is
opt-out for dev hosts without EtherCAT hardware.

### What it is

A native binary + systemd service that runs on the host (not inside a
Kubernetes pod). Uses the SOEM EtherCAT master library to drive the
EtherCAT bus from userspace at hard-realtime priority. Reads a JSON
configuration file describing the slave topology and motor parameters
for the specific robot hardware (e.g. `phantom-0009.json` for the
mk09 hardware revision).

Lives at:

- `/usr/sbin/dma_main` — the binary.
- `dma-ethercat.service` — the systemd unit (enabled + active when healthy).
- `/etc/dma/` — config tree (JSON files describing the EtherCAT bus topology).
- `/etc/dma/dma-ethercat.env` — runtime env file (`DMA_CONFIG`, `INTERFACE`, `DMA_CPU_AFFINITY`, `DMA_RT_CPU`).
- `/usr/local/share/dma/` — vendored binaries + the source `.deb`.

Bootstrap runs it on the host (not in a pod) because the EtherCAT
master needs:
- Direct raw-socket access to the NIC.
- Hard-realtime kernel scheduling (the `isolcpus=` cores from
  phase 10's CPU isolation).
- IRQ pinning on the NIC's interrupt to a specific core.

Kubernetes pods running with `runtimeClassName: nvidia` or even
privileged would still suffer from CFS scheduler latency that's
incompatible with EtherCAT's microsecond-scale timing budget.

### How bootstrap installs it (phase 12)

The install is a two-stage dance — a one-shot Kubernetes Job extracts
a `.deb` onto the host, then the bootstrap script `dpkg -i`s it. This
keeps the build artifact (the `.deb`) inside a container image
(easy to ship + version-pin via host-config's `images.dma-ethercat`)
without requiring all the host-side install steps to run inside a
container.

```
host-config.yaml
  images.dma-ethercat: foundationbot/dma-ethercat:main-latest
       │
       ▼
manifests/installers/dma-ethercat/base/job.yaml
  Job in phantom ns:
    image: foundationbot/dma-ethercat:<tag>   ← sed-substituted by bootstrap
    container's only job: cp /usr/local/share/dma/deb/dma-ethercat-*.deb
                          → hostPath /var/lib/dma-ethercat-installer/
                          touch .ready sentinel
                          exit 0
       │ (Job reaches Complete, pod reaps in 30s via TTL controller)
       ▼
bootstrap-robot.sh phase 12 (host side, as root):
  1. wait for .ready
  2. dpkg -i /var/lib/dma-ethercat-installer/dma-ethercat-*.deb
  3. write /etc/dma/dma-ethercat.env from host-config:
       DMA_CONFIG=<dmaEthercat.configPath, resolved against /etc/dma/>
       INTERFACE=<cpuIsolation.nic.iface>           (e.g. ecat1)
       DMA_CPU_AFFINITY=<isolcpus partition>        (e.g. 13-15)
       DMA_RT_CPU=<cpuIsolation.dmaRtCpu>           (e.g. 13)
  4. systemctl enable --now dma-ethercat.service
```

Bootstrap is intentionally strict here — phase 12 is `gates phase 13`,
meaning if the realtime service can't come up the GitOps phase doesn't
run either. The robot is non-functional without working motor
control; deploying ArgoCD on top of a broken realtime stack just
hides the failure.

Pass `--skip-ethercat-install` to bypass phase 12 on a re-run. The
flag preserves the previously-installed service if any.

### Configuration

Three host-config fields drive the install:

```yaml
cpuIsolation:
  nic:
    iface: ecat1                   # the NIC after phase 9 renames it
  dmaRtCpu: 13                     # CPU pinned to the SOEM cyclic loop
  partitions:
    - name: ecat
      cpus: 13-15                  # isolcpus= range; DMA_CPU_AFFINITY

images:
  dma-ethercat:
    image: foundationbot/dma-ethercat:main-latest          # amd64
    # foundationbot/dma-ethercat:main-latest-aarch64       # arm64

dmaEthercat:
  configPath: phantom-0009.json    # the JSON describing slave topology
```

`dmaEthercat.configPath` is resolved against the .deb's vendored
`/etc/dma/` tree (or `/usr/share/dma-ethercat/config/` depending on
the .deb version) — the wizard's CPU-isolation prompt picks a JSON
filename from there interactively.

### Day-2 operations

**Check status:**

```bash
sudo systemctl status dma-ethercat.service
sudo journalctl -u dma-ethercat.service -f          # follow logs
```

**Restart after editing a JSON config under `/etc/dma/`:**

```bash
sudo systemctl restart dma-ethercat.service
```

The service reads `/etc/dma/dma-ethercat.env` for the env vars and
then loads the JSON named in `DMA_CONFIG`. Re-reads on restart.

**Re-run the installer (e.g. after a `.deb` update on DockerHub):**

```bash
# Update the tag in host-config
sudo vim /etc/phantomos/host-config.yaml      # bump images.dma-ethercat.image

# Re-run phase 12 only
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh \
  --install-dma-ethercat
```

The re-install path defaults to also running the **uninstall** pre-phase
first, which WIPES `/etc/dma/` and re-creates it from the new `.deb`.
If you have hand-edited JSON configs you want to preserve, pass
`--skip-ethercat-uninstall` to skip the wipe.

**Switch to a different robot hardware config:**

```bash
sudo vim /etc/phantomos/host-config.yaml      # change dmaEthercat.configPath
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh \
  --install-dma-ethercat --skip-ethercat-uninstall
# the env file gets rewritten with the new DMA_CONFIG; service restarts
```

### Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Phase 12 Job pod `Pending` for 5+ min (`untolerated taint`) | Node has `disk-pressure` taint. Run `post-install-cleanup.sh` to free 15-18 GB. |
| Phase 12 Job pod `ImagePullBackOff` | Bundle has wrong-arch tag, OR containerd doesn't have the image. Check `k0s ctr -n k8s.io images list \| grep dma-ethercat` matches host-config's `images.dma-ethercat.image`. |
| Phase 12 succeeds but `systemctl status dma-ethercat` shows failed | NIC rename didn't happen (phase 9) — `INTERFACE=ecat1` in the env file but no such interface. Run `bootstrap-robot.sh --ecat-interface`. |
| `dma_main: bus error / no slaves found` in journal | EtherCAT bus is unplugged, slaves are unpowered, or the wrong NIC was picked. Verify with `sudo dma_main --scan -i ecat1` (lists discovered slaves). |
| Phase 10 says `Interface ecat1 not found` | Phase 9 didn't run or didn't pick a NIC. Re-run wizard's cpu-isolation prompt to set `nic.selector`, OR (dev host) set `cpuIsolation.enabled: false`. |
| Bootstrap halts at phase 12 — "ANY failure halts bootstrap" | Intentional — realtime stack must be healthy before GitOps. Resolve the underlying issue (one of the above), then re-run bootstrap. Pass `--skip-ethercat-install` only if you intentionally want a no-realtime cluster. |

### When to disable

On a dev host without EtherCAT hardware (e.g. a laptop running the
stack for UI/training-data work), set in host-config:

```yaml
cpuIsolation:
  enabled: false
```

Phases 7, 8, and 9 all skip cleanly. ArgoCD + all the cluster
workloads come up normally. dma-ethercat.service is never installed
and never tries to start.

---

## Re-running bootstrap

`bootstrap-robot.sh` is idempotent — phases that already completed will
print `SKIP` instead of re-doing work. Two pre-phases are destructive
by default:

- **Purge workload pods** — kills running pods in known namespaces
  (re-created automatically by their controllers).
- **Uninstall realtime control service** — wipes `/etc/dma/`
  (operator-edited JSON config files there are lost). Pass
  `--skip-ethercat-uninstall` to preserve them.

Useful flags:

- `--skip-ethercat-install` — skip phase 12 on a re-run.
- `--skip-ethercat-uninstall` — preserve existing `/etc/dma/` tree.
- `--gitops` — re-run only phase 13 (Argo Application render+apply).
  Useful after editing host-config to change `gitSource` or `images:`.
- `--image-overrides` — re-run only phase 15 (kustomize.images patches
  on the live Applications). Useful after re-running the wizard to
  change image refs without a full bootstrap cycle.

To **start over from a clean slate** (e.g. after a botched bootstrap
that left half-applied state, or before re-installing with a different
`.deb` version):

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/teardown.sh
```

Runs `bootstrap-robot.sh --reset` plus removes `/etc/phantomos`,
`/var/lib/k0s/images`, `/opt/Phantom-OS-KubernetesOptions`, the
`.deb` packages, and reverts the cpu-isolation kernel cmdline +
systemd CPUAffinity drop-in. After running, **reboot** to clear
`isolcpus=` from the kernel, then re-install from the top of this
guide. Pass `--keep-grub` to preserve the kernel cmdline across the
teardown/reinstall cycle.

---

## Post-install cleanup (recommended)

After verifying the cluster is healthy (step 5 above), run:

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/post-install-cleanup.sh
```

The image-bundle install drops ~15-18 GB of `*.tar` files into
`/var/lib/k0s/images/`. Once containerd has imported them (the
postinst's R2 step), those tarballs are redundant — the layers live
in containerd's content store. This script verifies every bundled
tarball is in containerd's local store, then deletes the `.tar`
files (keeping the `.phantomos-image-bundle.yaml` manifest as a
record). Typical disk savings: 15-18 GB.

Why not just delete unconditionally during install? The tarballs are
useful as a recovery backup — if containerd's content store ever gets
corrupted, re-running `install-image-bundle.sh` re-imports from the
on-disk tarballs without needing a fresh download. Cleanup is opt-in
once the operator has confirmed the install works.

Pass `--dry-run` to see what would be deleted before doing it.

If you SKIP this step, you may eventually hit a
`node.kubernetes.io/disk-pressure` taint when disk usage on `/` crosses
the kubelet's eviction threshold (default 90% used). Pods stop
scheduling, bootstrap halts on phase 12 (dma-ethercat installer pod
goes Pending and never starts). See "Common things that bite" below.

---

## Day-2 operations: changing host-config

After editing `/etc/phantomos/host-config.yaml`, re-run the right
bootstrap phase. Each command below is idempotent and completes in
seconds; pick the narrowest one that matches what you edited:

| You edited | Re-run | What it does |
|---|---|---|
| `images:` block | `bootstrap-robot.sh --image-overrides` | Re-renders each per-stack Application's `kustomize.images` from host-config. Argo reconciles within seconds. |
| `deployments:` block (mounts, privileged) | `bootstrap-robot.sh --deployments` | Re-renders strategic-merge patches on positronic-control + api-server. |
| `gitSource:` or `targetRevision:` | `bootstrap-robot.sh --gitops` | Re-renders the Application CRs themselves (repoURL + revision) + re-applies. Required when flipping local↔remote git source. |
| `stacks.<x>.enabled` | `bootstrap-robot.sh --gitops` | Renders Applications per enabled stack. Disabling a stack leaves its existing Application orphan in Argo (until RFC 0008 cleanup lands). |
| `stacks.<x>.selfHeal` or top-level `production:` | `bootstrap-robot.sh --gitops` | Updates the rendered Application's `syncPolicy.automated.selfHeal`. |
| `cpuIsolation:` cpus / partitions / dmaRtCpu | `bootstrap-robot.sh --cpu-isolation` then `sudo reboot` | Re-writes grub cmdline + systemd CPUAffinity. Kernel needs a reboot to pick up the new `isolcpus=`. |
| `cpuIsolation.nic.iface` / `selector` | `bootstrap-robot.sh --ecat-interface` | Re-resolves the NIC, re-writes the udev rule. |
| `aiPcUrl:` | `bootstrap-robot.sh --operator-ui-config` | Re-renders the `operator-ui-pairing` ConfigMap. Rolls operator-ui pod if the value changed. |
| `nodeLabels:` | `bootstrap-robot.sh --cluster` | Reconciles `foundation.bot/*` labels on the node. |
| `dmaEthercat.configPath` / `configSet` | `bootstrap-robot.sh --install-dma-ethercat` | Re-renders the installer Job + applies. |
| `logManagement:` | `bootstrap-robot.sh --log-management` | Updates journald + logrotate drop-ins. |
| **Anything / not sure** | `bootstrap-robot.sh` (no flags) | Runs all phases; each is idempotent and prints `SKIP` for phases where nothing changed. ~30 sec on a healthy cluster. |

Two safe rules of thumb:

1. **The no-flag re-run is always safe.** Each phase is idempotent —
   if nothing changed, it prints `SKIP`. Run this if you're not sure
   which flag applies.
2. **`--image-overrides` and `--gitops` are the most common Day-2
   actions.** Bump an image tag → `--image-overrides`. Switch git
   source mode → `--gitops`.

### Updating bundled images (new build)

If you changed the image bundled in the `.deb` (not just the
host-config ref), you also need to refresh the bundle itself:

**`gitSource: local`** (default — atomic via `.deb`):

```bash
# On the build host: rebuild the image bundle with new refs
bash scripts/build-images-deb.sh \
  --positronic-image foundationbot/phantom-cuda:<new-tag> \
  --phantom-models-image foundationbot/phantom-models:<new-tag> \
  --arch amd64

# Ship to the robot (matching version+arch on all three files)
scp dist/phantomos-k0s-*-all.deb robot:~/
scp dist/phantomos-k0s-images-*-amd64.{deb,tar.zst} robot:~/

# On the robot
sudo dpkg -i ./phantomos-k0s-*-all.deb
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh ./
# /opt/.../.git/ HEAD advances; Argo reconciles to the new SHA within seconds
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/post-install-cleanup.sh
```

**`gitSource: remote`** (GitHub-driven; image refs change but
manifest source stays at GitHub):

```bash
# On the robot
sudo vim /etc/phantomos/host-config.yaml          # bump image refs
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh --image-overrides
```

---

## Common things that bite

- **`data bundle not extracted`** during `dpkg -i` of the image `.deb` —
  you ran `dpkg -i` directly without extracting the sidecar first.
  Use `install-image-bundle.sh` instead — it handles both steps.
- **`bundle arch=<x> host arch=<y>`** — you scp'd the wrong-arch pair.
  Get the matching pair from the build host.
- **ImagePullBackOff with `REPLACE-WITH-*` in the image column** —
  shouldn't happen after RFC 0005's wizard fix. If it does, re-run
  `configure-host.sh` and let the auto-images path read from the bundle
  manifest, then `bootstrap-robot.sh --image-overrides`.
- **Argo Application stuck OutOfSync** — manifest source unreachable.
  Check `gitSource:` in host-config. If `local`, confirm
  `/opt/.../.git/` exists (it should, from the `.deb` install). If
  `remote`, confirm the GitHub URL is reachable from the
  argocd-repo-server pod.
- **Phase 10 cpu-isolation fails on `ecat1 not found`** — the host has no
  EtherCAT NIC and the wizard's CPU-isolation prompt was answered as
  enabled. Edit host-config: `cpuIsolation.enabled: false`, then re-run
  bootstrap.
- **A `dockerhub-creds missing` SKIP message** — only matters if a
  workload pulls a private DockerHub image not in the bundled set.
  With the image `.deb` installed, every standard image is on disk and
  the missing secret is a no-op.
- **Phase 12 (dma-ethercat installer) Job stuck in `Pending`, pod
  describe says `0/1 nodes are available: 1 node(s) had untolerated
  taint(s)`** — the kubelet auto-tainted the node with
  `node.kubernetes.io/disk-pressure:NoSchedule` because disk usage on
  `/` crossed the eviction threshold. The bundled image tarballs in
  `/var/lib/k0s/images/` plus containerd's unpacked layers can easily
  push a 200 GB disk past 90% used after a fresh install. Fix:
  ```bash
  sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/post-install-cleanup.sh
  ```
  Frees 15-18 GB by removing tarballs already imported into
  containerd. The kubelet untaints the node automatically once usage
  drops below the high watermark; the installer pod schedules and
  bootstrap proceeds. **Always run post-install-cleanup.sh after a
  successful first bootstrap** — see the "Post-install cleanup"
  section above.
- **Phase 10 (cpu-isolation) fails with `cpuIsolation.partitions and
  cpuIsolation.dmaRtCpu are required`** — host-config has a partial
  `cpuIsolation:` block (e.g. `enabled: true` plus a partition name
  but no cpus / dmaRtCpu / nic.iface). The pre-phase prompt fires when
  the block is completely absent, but skips when partial. Fix: either
  re-run `configure-host.sh` and complete the cpu-isolation prompts,
  or set `cpuIsolation.enabled: false` if this host has no EtherCAT
  hardware.

---

## Reference: command cheat sheet

```bash
# install
sudo dpkg -i ./phantomos-k0s-*-all.deb
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh ./

# configure + bootstrap
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/configure-host.sh
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh

# post-install: free 15-18 GB by removing redundant tarballs
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/post-install-cleanup.sh

# day-2: apply host-config changes (pick the narrowest one)
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh --image-overrides   # images:
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh --deployments       # deployments:
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh --gitops            # gitSource/targetRevision/stacks.*.enabled
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh                     # anything / not sure (idempotent)

# verify
sudo k0s kubectl get pods -A
sudo k0s kubectl -n argocd get applications

# inspect bundle on the robot
cat /var/lib/k0s/images/.phantomos-image-bundle.yaml

# run a policy on the control runtime
sudo bash /opt/.../scripts/positronic.sh status
sudo bash /opt/.../scripts/positronic.sh exec
sudo bash /opt/.../scripts/positronic.sh set-cmd /opt/positronic/bin/positronic-control --policy <name>
```
