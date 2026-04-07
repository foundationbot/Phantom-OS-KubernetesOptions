# k0s Implementation Plan — PhantomOS
> **Author:** Siddhant  
> **Date:** 2026-04-07  
> **Status:** Draft v1  
> **Companion doc:** [Edge Kubernetes Fit Analysis](https://github.com/foundationbot/Phantom-OS-KubernetesOptions/blob/main/edge-kubernetes-git-analysis.md)

---

## Decision Summary

After evaluating KubeEdge, MicroShift, k3s, and k0s against PhantomOS hard constraints, **k0s is selected** as the container orchestration layer for PhantomOS. The primary rejection criteria for alternatives:

- **KubeEdge** — requires cloud control plane, violates offline-first constraint
- **MicroShift** — RHEL-only, PhantomOS is Ubuntu LTS
- **k3s** — SQLite/Kine failure mode reproduced in our environment; unrecoverable in the field
- **RKE2** — native etcd, but 150-230% higher resource overhead; unacceptable on embedded robot hardware

---

## Phase 0 — Pre-Implementation (Before Writing Any Code)

These must be answered before a single line of k0s config is written. Skipping these causes rework.

### P0.1 — Audit current container state on the robot
**Effort:** half day  
**Goal:** Understand what is currently running so migration scope is known.

- SSH into the robot and document every running container (`docker ps` or equivalent)
- Document every systemd service (`systemctl list-units --type=service`)
- Identify which are already containerized vs running bare on the host
- Confirm motor controller is running as a host systemd service (not containerized)
- Output: a simple table of services → current deployment method

### P0.2 — Map the CPU layout on the Ubuntu dev machine
**Effort:** half day  
**Goal:** Know exactly which cores to isolate before touching the kernel or k0s config.

- Get core count and topology (`lscpu`, `numactl --hardware`)
- Identify which cores the motor controller thread(s) currently run on (check with `htop` or `taskset`)
- Determine isolation budget: how many cores for motor controller, how many for k0s control plane, how many for AI inference pods
- Output: a CPU allocation map that feeds directly into `isolcpus` kernel boot parameter and k0s kubelet config

> **Note:** This step focuses on the x86 Ubuntu dev environment. The same exercise will need to be repeated for Jetson Thor (AARCH64) when the deployment target moves to production hardware.

### P0.3 — Migrate from NixOS to Ubuntu LTS
**Effort:** 1 day  
**Goal:** Replace the current NixOS-based environment with Ubuntu LTS so that the rest of the implementation has a stable, supported base.

- Install Ubuntu LTS (x86-64) on the target dev machine / robot
- Reinstall all required system packages (containerd, systemd services, EtherCAT drivers, etc.)
- Re-deploy the motor controller as a host systemd service and confirm it runs
- Migrate any NixOS-specific configuration (nix flakes, `/etc/nixos/` config) to standard Ubuntu equivalents (`apt`, `/etc/systemd/`, `/etc/network/`)
- Validate all existing containers start and behave identically to the NixOS environment
- Output: Ubuntu LTS machine with the same working state as the previous NixOS setup

> **Why:** NixOS is not the target OS for PhantomOS — Ubuntu LTS is. Continuing to develop on NixOS risks accumulating NixOS-specific workarounds that will not transfer. This migration must happen before k0s installation to avoid doing it twice.

### P0.4 — Confirm k0s runs on x86 Ubuntu LTS
**Effort:** 2 hours  
**Goal:** Verify k0s binary boots cleanly on the Ubuntu LTS version in use.

- Download k0s binary, run `k0s version` on the Ubuntu dev machine
- Confirm no conflicts with containerd or kernel version
- Output: go/no-go signal before any integration work starts

---

## Phase 1 — Single-Node k0s Baseline

**Target:** k0s running on the Ubuntu x86 dev machine in single-node (controller+worker) mode with no workloads. Just the cluster, healthy.

> **Note:** All Phase 1–5 work targets Ubuntu x86 first. Once validated, the same configuration will be ported to Jetson Thor (AARCH64) for production deployment. Thor-specific concerns (JetPack BSP, arm64 binary, GPU memory allocation) are deferred until the Ubuntu deployment is proven.

**Effort:** ~1.5 days  
**Target date:** April 10 (aligns with roadmap k3s architecture design gate)

### Tasks

**1.1 — Install k0s in single-node mode**
- Install k0s binary on the Ubuntu dev machine
- Configure as combined controller+worker (`k0s install controller --single`)
- Confirm `k0s status` shows healthy
- Confirm etcd is running (not SQLite — verify explicitly)
- Confirm `kubectl get nodes` returns the node in Ready state

**1.2 — Kernel CPU isolation**
- Add `isolcpus=<motor-controller-cores>` to kernel boot parameters (based on P0.2 output)
- Add `nohz_full=<same cores>` and `rcu_nocbs=<same cores>` for full RT isolation
- Reboot, verify isolated cores are invisible to k0s scheduler
- Verify motor controller still starts and runs on isolated cores post-reboot

**1.3 — k0s kubelet CPU Manager configuration**
- Enable CPU Manager static policy in kubelet config
- Reserve cores for system and k0s control plane (`systemReserved`, `kubeReserved`)
- Verify remaining cores are available for pod pinning

**1.4 — Smoke test**
- Deploy a single test pod with Guaranteed QoS + whole CPU request
- Verify it is pinned to non-isolated cores (`cat /sys/fs/cgroup/cpuset/.../cpuset.cpus`)
- Verify motor controller cores are untouched

---

## Phase 2 — Container Migration

**Target:** All existing containers running as k0s pods. Motor controller remains as host systemd service.

**Effort:** ~1 week  
**Target date:** April 25 (aligns with roadmap container migration gate)

### Containers to migrate (to be confirmed from P0.1 audit)

| Container | Notes |
|---|---|
| DMA.video | Host networking — use `hostNetwork: true` in pod spec |
| Positronic control | Guaranteed QoS, pin to AI inference cores |
| Tele-op | Standard pod |
| Operator UI | Standard pod |
| Prometheus | Standard pod |
| Grafana | Standard pod |
| Node exporter | DaemonSet, needs host access |
| Fluentd | DaemonSet, needs host log access |

### Migration approach per container
1. Write k0s pod manifest (or Helm chart if complex)
2. Deploy on x86 Ubuntu dev machine, validate behaviour matches pre-migration
3. Remove old Docker/systemd equivalent only after validation

### Key constraints
- Motor controller: **never** migrated. Stays as `phantom-controller.service` on the host.
- DMA queues: pods that use DMA shared memory need `hostIPC: true` or explicit shared memory volume mounts — confirm with Gaurav which mechanism is in use
- Host networking: latency-sensitive pods (positronic control, DMA.video) use host networking, not k0s overlay network

---

## Phase 3 — GitOps Layer (ArgoCD)

**Target:** All pods deployed and managed via ArgoCD from the config repo. No manual `kubectl apply`.

**Effort:** ~2.5 days  
**Target date:** May 2 (aligns with roadmap ArgoCD gate)

### Tasks

**3.1 — Deploy ArgoCD into k0s**
- Install ArgoCD via manifests into the k0s cluster
- Expose ArgoCD UI (NodePort or host networking)
- Connect to the foundationbot config repo

**3.2 — Migrate manifests to GitOps**
- Move all pod manifests from Phase 2 into the config repo
- One directory per robot identity (`phantom-xxxyyy/`)
- ArgoCD watches the config repo and syncs to the robot

**3.3 — Validate rollback**
- Push a bad manifest, confirm ArgoCD detects drift
- Revert commit, confirm ArgoCD reconciles back to healthy state

---

## Phase 4 — Local OCI Registry + OTA Downloader

**Target:** Robot has a local image registry. New container images can be pushed from cloud and pulled without SSH.

**Effort:** ~1.5 days  
**Target date:** May 7 (aligns with roadmap registry updater gate)

### Tasks
- Deploy a local OCI registry (e.g. `registry:2`) as a k0s pod
- Write OTA downloader service: polls cloud registry for new image tags, pulls to local registry
- ArgoCD picks up new image tags from config repo → pods restart with new image
- Validate offline: disconnect network, confirm cluster and workloads continue running

---

## Phase 5 — Logging Pipeline

**Target:** All container logs stream to cloud via Fluentd. Operator error snapshot works.

**Effort:** ~2.5 days  
**Target date:** May 9 (aligns with roadmap Fluentd gate)

### Tasks
- Deploy Fluentd as DaemonSet in k0s
- Configure to read from systemd/journald (captures both pod logs and host services including motor controller)
- Add offline buffer: logs queue locally when disconnected, flush on reconnect
- Implement operator error snapshot: trigger captures last N minutes of logs + system state

---

## Open Questions (Bring to Architecture Meeting)

| # | Question | Why it blocks us |
|---|---|---|
| OQ-1 | Which specific cores does the motor controller currently use on the dev machine? | Blocks P0.2 and Phase 1 CPU isolation |
| OQ-2 | How do DMA pods access shared memory — `hostIPC`, hugepages, or `/dev/shm` mount? | Blocks Phase 2 pod manifests for positronic control and DMA.video |
| OQ-3 | Is there an existing container list on the robot? | Blocks Phase 2 migration scope |
| OQ-4 | What is the robot's current network interface setup? | Affects host networking config for latency-sensitive pods |
| OQ-5 | Who owns the config repo structure decision? | Blocks Phase 3 ArgoCD setup |

---

## Timeline Summary

| Phase | What | Effort | Target |
|---|---|---|---|
| Phase 0 | Audit + CPU map + NixOS→Ubuntu migration + k0s verify | ~3 days | Apr 8–10 |
| Phase 1 | k0s baseline + CPU isolation | ~1.5 days | Apr 10 |
| Phase 2 | Container migration | ~1 week | Apr 25 |
| Phase 3 | ArgoCD GitOps | ~2.5 days | May 2 |
| Phase 4 | Local registry + OTA | ~1.5 days | May 7 |
| Phase 5 | Logging pipeline | ~2.5 days | May 9 |

**Phase 1 complete = May 12** (matches roadmap gate)

---

## Risks

| Risk | Mitigation |
|---|---|
| k0s etcd overhead competes with AI inference | CPU map (P0.2) must be done before Phase 1. If overhead is too high, pin k0s control plane to dedicated cores. |
| DMA shared memory incompatible with k0s pod isolation | Confirm mechanism with Gaurav before Phase 2. `hostIPC` is the likely answer. |
| Current containers have undocumented dependencies | Phase 0 audit is mandatory. Do not skip. |
| Motor controller accidentally scheduled into k0s | Use `nodeSelector` + `taints` to make the host motor controller cores fully invisible to k0s scheduler |
| Thor (AARCH64) deployment deferred | All work validated on Ubuntu x86 first. Thor port may surface BSP/JetPack-specific issues (kernel version, GPU driver conflicts, arm64 binary compatibility) that require additional effort. |