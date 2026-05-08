# Quick start

Five steps to bring up a fresh robot from clean Ubuntu to a fully
running cluster. Tested on `aarch64` and `amd64`. Sudo is required
throughout.

---

## What you'll need

- Ubuntu 24.04 on the robot, with root access.
- Both `.deb` files transferred to the robot (e.g. via scp into
  `~/k0s-deploy/`):
  - The control plane package: `*-all.deb` (scripts + manifests).
  - The image package: `*-<arch>.deb` (pre-pulled container images;
    pick the one matching your robot's architecture, `amd64` or
    `arm64`).
- About 30 minutes of operator attention. The setup wizard asks
  roughly 15 questions; most have sensible defaults you can accept
  by pressing Enter.

---

## Setup steps

### 1. Install the two `.deb` files

```bash
sudo dpkg -i phantomos-k0s-*-all.deb
sudo dpkg -i phantomos-k0s-images-*-arm64.deb     # or -amd64.deb
```

The first installs scripts + manifests under
`/opt/Phantom-OS-KubernetesOptions/`. The second drops pre-pulled
container image tarballs into `/var/lib/k0s/images/` so k0s imports
them at worker startup — no DockerHub access needed for any bundled
image.

### 2. Run the configure wizard

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/configure-host.sh
```

The wizard walks through `/etc/phantomos/host-config.yaml`. Press Enter
to accept any default. Things you'll be asked:

| Prompt | What to answer |
|---|---|
| **robot** | DNS-safe robot name, e.g. `mk09` |
| **AI PC pairing** | Either type a Tailscale URL (`http://100.x.y.z:5000`) or answer **y** to auto-detect from the robot's default-gateway interface. The wizard reports the detected interface and IP. |
| **targetRevision** | Git branch ArgoCD will track. `main` for production. |
| **production mode** | `n` for dev/debug machines (no auto-revert of `kubectl edit`s); `y` for production robots. |
| **stack toggles** | Press Enter to accept defaults: core (always on), operator (on). |
| **image overrides** | Press Enter to accept seed defaults; bump tags only when you know you need a specific build. |
| **deployment mounts** (control runtime) | Pick `production` preset (4 standard mounts: data partitions, recordings, model cache) for normal robots. |
| **deployment mounts** (api server) | Answer `n` unless you have on-host project trees to expose into the api pod. |

When the wizard finishes it offers to run `bootstrap-robot.sh`
immediately. Answer **y** to chain into step 3.

### 3. Bootstrap the cluster

If you didn't auto-chain from the wizard:

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh
```

Bootstrap runs ~15 phases. You'll see another two prompts during the
run:

- **CPU isolation**: partition cpus (`11-13`), partition name
  (`ecat`), NIC interface (`ecat0`), NIC IRQ core (`11`), realtime
  loop core (`12`), install systemd CPUAffinity drop-in (`Y`).
  Defaults match most setups — accept them unless you know better.
- **Realtime hardware config**: a numbered list of JSON configs.
  Pick the one matching your robot's hardware. If unsure, ask
  whoever provisioned the robot — the filename is usually printed
  on the chassis label or in the handover notes.

You'll also be prompted for a new **ArgoCD admin password** — pick
something memorable and store it; the password is needed later to log
into the ArgoCD UI.

### 4. Confirm everything's running

```bash
sudo k0s kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,IMAGES:.spec.containers[*].image'
```

Expect about 30 pods across roughly 8 namespaces. `STATUS` should be
`Running` for almost all of them (or `Completed` for one-shot Jobs).
A healthy cluster has pods in:

| Namespace | What it does |
|---|---|
| `argocd` | GitOps controller (manages all the others) |
| `argus` | Operator user-interface stack |
| `dma-video` | Video pipeline |
| `nimbus` | Episode / data storage |
| `phantom` | On-robot agents |
| `positronic` | Control runtime |
| `registry` | Local container image registry |
| `kube-flannel`, `kube-system` | Kubernetes plumbing |

Any pod stuck in `Pending` / `ImagePullBackOff` usually means an image
override in `host-config.yaml` is still set to a `REPLACE-WITH-...`
placeholder. Edit `/etc/phantomos/host-config.yaml` to set a real tag,
then re-run bootstrap.

### 5. Access the ArgoCD UI

```bash
# print the admin password you set in step 3
sudo k0s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

Browse to `https://<robot-ip>:30443` and log in as `admin` with the
password above. From here every workload is git-driven — edit a file
under `manifests/`, push, and ArgoCD reconciles within ~3 minutes.

---

## Re-running bootstrap

You can re-run `bootstrap-robot.sh` at any time. It's idempotent —
phases that have already completed will print `SKIP` instead of
re-doing the work. Two pre-phases are destructive by default though:

- **Purge workload pods** — kills running pods in known namespaces
  (they get re-created automatically by their controllers).
- **Uninstall realtime control service** — wipes `/etc/dma/`
  (operator-edited JSON config files there will be lost). Pass
  `--skip-ethercat-uninstall` to preserve them.

Pass `--skip-ethercat-install` to avoid reinstalling the realtime
service on a re-run; pass `--skip-ethercat-uninstall` to keep the
existing `/etc/dma/` tree.

---

## Common things that bite

- **A `dockerhub-creds missing` SKIP message** — only matters if any
  workload needs to pull an image from a private DockerHub repo. With
  the image `.deb` installed, every standard image is already on disk
  and the missing secret is a non-issue (bootstrap prints SKIP and
  continues). If you've added a custom workload that pulls from a
  private repo, run `sudo docker login` once on the robot and re-run
  bootstrap — that seeds the credentials.
- **`terraform apply` errors with AlreadyExists / "name still in use"**
  — leftover state from an earlier partial bootstrap. The next
  bootstrap run will auto-recover by importing the existing resources
  into terraform state. If you still hit it on other resources, the
  nuclear reset is:
  ```bash
  sudo k0s kubectl delete ns argocd --grace-period=0 --force
  sudo rm -f /opt/Phantom-OS-KubernetesOptions/terraform/terraform.tfstate*
  sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh
  ```
- **Pods stuck in `Pending` with `REPLACE-WITH-...` in the image
  column** — the host-config.yaml `images:` block has placeholder
  tags. Edit `/etc/phantomos/host-config.yaml`, set the real tags
  for your build, then re-run bootstrap.
- **`No resources found in <namespace>`** — the GitOps phase didn't
  run on this robot, usually because an earlier phase failed and
  bootstrap halted. Scroll up the bootstrap output for any FAIL line,
  resolve the underlying issue, and re-run. Phases stop at the first
  failure unless `--keep-going` is passed.
