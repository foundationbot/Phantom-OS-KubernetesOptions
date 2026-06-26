# Requirements

What every robot needs to have in place **before** running
`bootstrap-robot.sh`. Read this first.

If a requirement here isn't met, bootstrap will either refuse to start
or silently leave parts of the cluster broken in ways that are hard to
diagnose later.

For installation steps once requirements are met, see
[`quickstart-install.md`](quickstart-install.md).

---

## Hardware

| Component | Required | Notes |
|---|---|---|
| Architecture | x86-64 or arm64 (Jetson Thor) | Image bundle is per-arch; match the `.deb` to the host. |
| CPU cores | 14 minimum, 20 recommended | Manifests sized for 20-core robots; smaller hosts need overlay tweaks. |
| RAM | 16 GiB minimum | k0s + workloads + ArgoCD. |
| Disk | 200 GiB free on `/` | ~50 GiB for cluster runtime + the bundled image set (~15-18 GiB after extraction); headroom for image layers + recordings. |
| Network | Reachable from operator's machine | SSH for bring-up; outbound internet **only** during initial k0s install. After bootstrap, air-gapped operation is supported (RFC 0006 — Argo tracks the local `/opt/.../.git/`, no GitHub round-trip). |

### **NVIDIA GPU — required for positronic-control**

The positronic-control container is **CUDA-only**. Without an NVIDIA
GPU and the matching software stack, the `positronic-control` pod will
either fail to schedule (no `nvidia` runtimeClass on the host) or
crash on startup (CUDA libraries missing). Other workloads (argus,
dma-video, nimbus, operator-ui) do not require a GPU.

**On the host, before running `bootstrap-robot.sh`:**

- **NVIDIA driver** installed and loaded (`nvidia-smi` reports the GPU).
- **`nvidia-container-toolkit`** installed
  (`apt install nvidia-container-toolkit`).
- **`nvidia-container-runtime`** binary in PATH
  (`command -v nvidia-container-runtime`).

Bootstrap's phase 4 auto-detects NVIDIA via `lspci` or `/dev/nvidia0`
and runs `scripts/configure-k0s-nvidia-runtime.sh` to register the
runtime with k0s's containerd. If detection fails, the pod's
`runtimeClassName: nvidia` reference resolves to "no runtime
configured" and `FailedCreatePodSandBox` events fire.

If you are **deliberately running on a host without an NVIDIA GPU**
(e.g. a dev workstation for non-positronic workloads), the
positronic-control pod will stay in `Init:` or `ContainerCreating`
forever. That's expected on no-GPU hardware. Don't waste time
debugging it — disable the positronic stack in host-config if you
truly don't need it.

---

## Host OS

- **Ubuntu 24.04 LTS** with `sudo` available for the install operator.
- `/etc/default/grub` writable (bootstrap edits the kernel cmdline
  when CPU isolation is enabled).
- Static IP (or DHCP reservation) for the host. The cluster API
  server, ArgoCD UI, and operator-UI all bind to this address — DHCP
  lease renewal will break those services.

---

## EtherCAT NIC (production robots only)

For production robots that run real-time motor control, the host
needs:

- A dedicated EtherCAT-capable NIC (Intel i210, i225, i350 family
  typical).
- The NIC's MAC address or PCI ID recorded (so the wizard's
  cpuIsolation prompt can write a stable `nic.selector`).

Dev workstations without EtherCAT hardware should answer **`n`** to
the wizard's CPU-isolation prompt (`cpuIsolation.enabled: false`).
Phases 7/8/9 skip cleanly; the rest of the stack comes up normally.

---

## Tailscale (optional)

For remote ops access to the robot's services. Not required for local
operation. Install **before** running `bootstrap-robot.sh` if you
want the wizard's AI-PC-pairing prompt to use a Tailscale URL.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

---

## DockerHub credentials (mostly optional)

The image bundle ships pre-pulled tarballs for every standard
`foundationbot/*` image. On a normal bringup, the robot does not need
DockerHub access — containerd serves from the local image store after
the bundle import.

You only need DockerHub credentials if:

- You're going to deploy a workload whose image isn't in the bundle.
- You opt-in to remote-git mode (`gitSource: remote` in host-config)
  AND a manifest change adds a new image not in the bundle.

If needed: run `docker login` once on the host before bootstrap. The
seed-pull-secrets phase pulls credentials from `~/.docker/config.json`
and creates `dockerhub-creds` Secrets in the relevant namespaces.

---

## What you'll need to install

Three files transferred to the robot's home directory:

- `phantomos-k0s-<version>-all.deb` — control-plane (~MB-scale).
- `phantomos-k0s-images-<version>-<arch>.deb` — image bundle metadata (~tens of KB).
- `phantomos-k0s-images-<version>-<arch>.tar.zst` — image data (multi-GB).

See `quickstart-install.md` for the step-by-step install flow.
