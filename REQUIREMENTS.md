# PhantomOS on k0s — Requirements & Assumptions

What you must have in place **before** running `terraform apply` against a robot, and what this repo assumes about the target environment. Read this first.

For the deeper architecture rationale, see [architecture-decision-argocd-topology.md](architecture-decision-argocd-topology.md). For the rollout phasing, see [kos-implmentation-plan-v1.md](kos-implmentation-plan-v1.md).

---

## Scope

This repo deploys three workload stacks — `argus`, `dma-video`, `nimbus` — onto a single robot running k0s, managed by ArgoCD.

It **does**: install ArgoCD, apply the root app-of-apps, and reconcile workloads from git.

It **does not**: install k0s, install the host OS, configure kernel CPU isolation, manage motor controller systemd, or create per-cluster credentials. Those are operator responsibilities — covered below.

---

## Hardware assumptions

| Item | Required | Notes |
|---|---|---|
| Architecture | x86-64 or arm64 (Jetson Thor) | Multi-arch images cover both |
| CPU cores | 14 minimum, 20 recommended | Base manifests sized for 20-core robot; smaller hardware needs overlay tweaks (see Session C in the architecture doc) |
| RAM | 16 GiB minimum | k0s + workloads + ArgoCD stack |
| Disk | 200 GiB free | Includes 150 GiB for the local registry PV and 500 GiB for the recordings PV (the recordings PV uses hostPath at `/root/recordings`) |
| Network | Reachable from the operator's machine | SSH for bring-up, plus outbound internet for image pulls and git |

---

## Host OS assumptions

- **Ubuntu LTS** (22.04 or 24.04). Not NixOS, not RHEL.
- `root` access via SSH key auth (no password prompts during bring-up).
- `sudo` available for the operator account.
- containerd is the runtime — k0s bundles it; do not pre-install Docker or k3s. If k3s is present, uninstall first ([README.md:91](README.md#L91)).
- Kernel boot params for real-time isolation are set in GRUB before k0s install:
  - `isolcpus=<motor-cores>` `nohz_full=<motor-cores>` `rcu_nocbs=<motor-cores>`
  - On Jetson Thor (mk09): cores 10–13 are isolated; the host motor controller runs there.
  - On the 20-core x86 reference: cores 15–19 are isolated.

---

## Kubernetes assumptions

- **k0s v1.35.x**, single-node controller+worker (`k0s install controller --single`).
- **etcd** as the datastore, not SQLite/Kine. Verify explicitly after install.
- **Flannel** as the CNI on Tegra-kernel hardware (kube-router does not work on Jetson — Tegra kernel lacks `ip_set_hash_*` modules). On Intel hardware, kube-router is fine.
- A kubeconfig with cluster-admin access exported to the machine running `terraform apply` (via Tailscale, or local on the robot).

---

## Networking assumptions

- **Outbound internet** from the robot for: DockerHub image pulls, GitHub git pulls, AWS IoT (for nimbus eg-jobs).
- **Tailscale** on the robot for remote operator access. The operator's machine and the robot share a tailnet.
- **NodePorts open on the robot** for in-cluster service exposure:
  - `30080` — argus operator UI (nginx)
  - `30081` / `30443` — ArgoCD UI (HTTP / HTTPS)
- **Host networking** for `dma-video` pods (camera pipeline cannot tolerate the CNI overlay's added latency).

---

## Required accounts & credentials

These do **not** live in git. The operator creates them on the robot before workloads can come up healthy.

| Credential | Where it lives on the cluster | Used by |
|---|---|---|
| DockerHub deployment account PAT | `dockerhub-creds` Secret in `argus`, `dma-video`, `nimbus` namespaces | All pods that pull `foundationbot/*` images |
| AWS IoT certs | `iot-certs` Secret in `nimbus` | `eg-jobs` for S3 upload via IoT Core |
| ArgoCD admin password | Auto-generated `argocd-initial-admin-secret` in `argocd` | First UI login (rotate after) |

> **Use the `foundationbot` deployment DockerHub account** — not a personal account. Personal-account PATs leak the engineer's identity into every pod-pull audit log and break when the engineer leaves.

The pre-bring-up command sequence for credentials:

```bash
# DockerHub pull secrets — one per namespace
for ns in argus dma-video nimbus; do
  kubectl create secret docker-registry dockerhub-creds \
    --namespace "$ns" \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=foundationbot \
    --docker-password=<PAT_FROM_SECRETS_MANAGER>
done

# AWS IoT certs for nimbus eg-jobs
kubectl -n nimbus create secret generic iot-certs \
  --from-file=cert.pem=/path/to/cert.pem \
  --from-file=private.key=/path/to/private.key \
  --from-file=root-CA.crt=/path/to/AmazonRootCA1.pem
```

---

## Operator workstation assumptions

The machine running `terraform apply`:

- Terraform >= 1.10
- `kubectl` in `PATH`
- `helm` provider (Terraform pulls automatically)
- A kubeconfig exported from the target robot (`/var/lib/k0s/pki/admin.conf`), reachable over Tailscale
- Read access to the `foundationbot/Phantom-OS-KubernetesOptions` repo (public; no auth needed today)

---

## Per-robot overlay requirement

Each robot has a directory under `manifests/robots/<robot-name>/` containing:

- `kustomization.yaml` — sets `commonAnnotations.robot`, declares `resources` (the three base stacks), pins per-robot image SHAs, applies any robot-specific patches
- `patches/` — robot-specific Deployment/StatefulSet patches (e.g. mk09's `operator-ui-env.yaml` injects the AI PC URL)

A matching ArgoCD Application CR must exist under `gitops/apps/phantomos-<robot>.yaml` pointing at that overlay.

Onboarding a new robot is mechanical:

1. `cp -r manifests/robots/argentum manifests/robots/<new>` and edit annotations + image pins
2. `cp gitops/apps/phantomos-argentum.yaml gitops/apps/phantomos-<new>.yaml` and edit `path` + `name`
3. Provision k0s on the robot per the OS-level requirements above
4. Create the credentials listed in the "Required accounts" section
5. `terraform apply -var='kubeconfig=~/.kube/<new>'`

---

## What is explicitly **out of scope**

- Provisioning the robot OS / installing k0s / setting kernel boot params — operator does this manually
- Motor controller deployment — runs as host systemd (`phantom-controller.service`), never as a pod
- Secrets management beyond manual `kubectl create secret` — a future iteration moves this to External Secrets Operator + AWS Secrets Manager
- Fluentd / log shipping — Phase 5 of the implementation plan, not yet built
- OTA image distribution — Phase 4, partial (local registry deployed, downloader pending)
- Multi-robot orchestration — the architecture decision is to move to central ArgoCD on AWS, but the POC is per-robot ArgoCD ([architecture-decision-argocd-topology.md](architecture-decision-argocd-topology.md))

---

## Checklist — "Am I ready to `terraform apply`?"

- [ ] Robot running Ubuntu LTS, not NixOS
- [ ] Kernel boot params set: `isolcpus`, `nohz_full`, `rcu_nocbs` on motor cores
- [ ] k0s installed, single-node controller+worker, `k0s status` healthy
- [ ] etcd confirmed as datastore (not Kine/SQLite)
- [ ] CNI confirmed (Flannel on Jetson, kube-router on Intel)
- [ ] Tailscale connected; operator workstation can reach robot's kube-apiserver
- [ ] Kubeconfig exported and tested (`kubectl get nodes` returns Ready)
- [ ] `dockerhub-creds` secret created in `argus`, `dma-video`, `nimbus`
- [ ] `iot-certs` secret created in `nimbus`
- [ ] Per-robot overlay directory exists at `manifests/robots/<name>/`
- [ ] Matching `gitops/apps/phantomos-<name>.yaml` Application CR exists and is committed

If every box is checked, `cd terraform && terraform apply` will leave the robot in steady-state ArgoCD-managed mode. From that point, no `kubectl apply` is performed by hand — every change flows through git.
