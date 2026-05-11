# Quick start — install Phantom-OS on a robot

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
- **Realtime hardware config** (phase 9, only when CPU isolation is
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

Expect about 30 pods across 8 namespaces. `STATUS` should be `Running`
for almost all (or `Completed` for one-shot Jobs). Healthy namespaces:

| Namespace | What it does |
|---|---|
| `argocd` | GitOps controller |
| `argus` | Operator user-interface stack |
| `dma-video` | Video pipeline |
| `nimbus` | Episode / data storage |
| `phantom` | On-robot agents |
| `positronic` | Control runtime |
| `registry` | Local container image registry (RFC 0006 does not depend on this for manifest source) |
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

- `--skip-ethercat-install` — skip phase 9 on a re-run.
- `--skip-ethercat-uninstall` — preserve existing `/etc/dma/` tree.
- `--gitops` — re-run only phase 10 (Argo Application render+apply).
  Useful after editing host-config to change `gitSource` or `images:`.
- `--image-overrides` — re-run only phase 12 (kustomize.images patches
  on the live Applications). Useful after re-running the wizard to
  change image refs without a full bootstrap cycle.

---

## Updating images on a deployed robot

Two paths, depending on `gitSource`:

**`gitSource: local`** (default — atomic via `.deb`):

```bash
# On the build host: rebuild the image bundle with new refs
bash scripts/build-images-deb.sh \
  --positronic-image foundationbot/phantom-cuda:<new-tag> \
  --phantom-models-image localhost:5443/phantom-models:<new-tag> \
  --arch amd64

# Ship to the robot
scp dist/phantomos-k0s-*-all.deb robot:~/
scp dist/phantomos-k0s-images-*-amd64.{deb,tar.zst} robot:~/

# On the robot
sudo dpkg -i ~/phantomos-k0s-*-all.deb
sudo bash /opt/.../scripts/install-image-bundle.sh ./
# /opt/.../.git/ HEAD advances; Argo reconciles within seconds
```

**`gitSource: remote`** (GitHub-driven):

```bash
# On the robot
sudo vim /etc/phantomos/host-config.yaml          # bump image refs
sudo bash /opt/.../scripts/bootstrap-robot.sh --image-overrides
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
- **Phase 8 cpu-isolation fails on `ecat1 not found`** — the host has no
  EtherCAT NIC and the wizard's CPU-isolation prompt was answered as
  enabled. Edit host-config: `cpuIsolation.enabled: false`, then re-run
  bootstrap.
- **A `dockerhub-creds missing` SKIP message** — only matters if a
  workload pulls a private DockerHub image not in the bundled set.
  With the image `.deb` installed, every standard image is on disk and
  the missing secret is a no-op.

---

## Reference: command cheat sheet

```bash
# install
sudo dpkg -i ~/phantomos-k0s-*-all.deb
sudo bash /opt/.../scripts/install-image-bundle.sh ./

# configure + bootstrap
sudo bash /opt/.../scripts/configure-host.sh
sudo bash /opt/.../scripts/bootstrap-robot.sh

# quick re-run after host-config change
sudo bash /opt/.../scripts/bootstrap-robot.sh --image-overrides
sudo bash /opt/.../scripts/bootstrap-robot.sh --gitops

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
