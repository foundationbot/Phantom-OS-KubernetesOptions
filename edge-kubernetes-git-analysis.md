# Edge Kubernetes Options — Fit Analysis for PhantomOS

> **Author:** Siddhant  
> **Date:** 2026-04-07  
> **Purpose:** Evaluate lightweight Kubernetes distributions for PhantomOS before committing to an architecture. Each option is assessed against PhantomOS-specific constraints and failure modes.

---

## PhantomOS Hard Constraints

Before evaluating any distribution, these are the non-negotiable requirements that any choice must satisfy:

1. **Motor controller is a host systemd service — never containerized.** The k8s distribution must not interfere with it. CPU cycles, kernel scheduling, and network I/O from the orchestration layer must be isolatable from the RT control loop.
2. **Offline-first.** Robots operate in warehouses, factory floors, and field environments with no guaranteed internet connectivity. The cluster must be fully operational with zero cloud dependency.
3. **Single-node per robot, fleet of robots.** Each robot runs its own cluster. Fleet management (OTA, config push) is a separate concern owned by FleetOS — not the on-robot orchestrator.
4. **Ubuntu LTS (x86-64 and AARCH64 / Jetson Thor).** The OS is fixed. Any distribution that requires a different OS base is disqualified.
5. **Production longevity.** Robots run 24/7. The orchestration layer must not degrade over time under sustained write load. A DB failure that requires manual recovery on a robot in the field is a critical failure mode.
6. **Real-time safety.** The orchestration layer must support CPU isolation and CPU pinning. k8s pods must not be able to preempt motor controller threads.

---

## Option 1: KubeEdge

### What it is
KubeEdge is a CNCF graduated project from Huawei Cloud. It extends Kubernetes to edge nodes by splitting the control plane into two tiers: a **CloudHub** running in the cloud and an **EdgeHub** running on the device. The edge node syncs state from the cloud and can run workloads locally.

### Why it fails for PhantomOS

**Fundamental architecture mismatch.** KubeEdge is designed around the assumption that there is a persistent cloud control plane. The edge node is a managed *leaf* — it receives its orchestration state from the cloud. PhantomOS robots must be *autonomous nodes* that operate independently of any cloud connection.

Concretely:
- If the robot loses connectivity, KubeEdge edge nodes enter a degraded state. Application management (deploy, rollback, restart) becomes unavailable until cloud sync resumes. This directly violates the offline-first constraint.
- CloudHub is a separate infrastructure component that the PhantomOS team would have to operate. This is operational overhead that doesn't exist in a self-contained distribution. It also introduces a dependency between robot uptime and cloud infrastructure uptime — unacceptable for a production robotics platform.
- KubeEdge's local metadata store on the edge node is SQLite — the same failure mode as k3s.

**Verdict: Eliminated.** KubeEdge solves cloud-to-edge orchestration at scale. PhantomOS is not that problem. The robot is the edge — it needs to own its own control plane entirely.

---

## Option 2: MicroShift (Red Hat Device Edge)

### What it is
MicroShift is a minimal OpenShift/Kubernetes distribution from Red Hat, designed for embedded and edge devices with constrained resources. It is part of the Red Hat Device Edge product and is purpose-built for air-gapped, offline, and disconnected environments. It embeds the Kubernetes control plane as a single binary and is designed to run on immutable OS images (RHEL for Edge, rpm-ostree).

### Why it fails for PhantomOS

**OS lock-in.** MicroShift is built for and tested on Red Hat Enterprise Linux (RHEL) for Edge using rpm-ostree. PhantomOS is Ubuntu LTS. This is not a configuration difference — it is a fundamental incompatibility. The toolchain (Image Builder, composer-cli, rpm-ostree), the update mechanism (ostree commits), and the package system (RPM) are all RHEL-specific.

Adopting MicroShift would mean:
- Rebuilding the entire PhantomOS base image on RHEL for Edge instead of Ubuntu LTS
- Abandoning the existing apt-based package pipeline and CI/CD tooling
- Taking on a Red Hat subscription for production deployments
- Re-validating everything — motor controller, DMA stack, EtherCAT drivers, CUDA/TensorRT — on a new OS

The offline resilience MicroShift provides is real and well-engineered. But it is not unique to MicroShift. The PhantomOS roadmap already specifies a local OCI registry on the robot and an on-robot system updater. The same offline capability can be achieved with k0s on Ubuntu.

**Verdict: Eliminated.** MicroShift is the right answer if you are building on Red Hat from scratch. PhantomOS is not. The OS migration cost is not justified when the offline features can be replicated on the existing stack.

---

## Option 3: k3s

### What it is
k3s is a CNCF-certified lightweight Kubernetes distribution from Rancher (SUSE). It packages Kubernetes as a single binary under 100MB, replaces etcd with an embedded SQLite database by default (via a shim called Kine), and bundles opinionated defaults including Flannel CNI and Traefik ingress. It is the most widely deployed lightweight Kubernetes distribution in the world.

### Why it fails for PhantomOS

**The SQLite failure mode is a production blocker.** k3s defaults to SQLite via Kine (Kine Is Not Etcd) as its cluster state datastore. This has been directly reproduced as a failure in our environment.

The failure mechanism:
- The Kubernetes API server stores every object change as a new revision in the datastore
- Kine runs periodic compaction to delete old revisions and prevent unbounded DB growth
- Under sustained load — container restarts, config changes, OTA updates, telemetry writes — the DB grows faster than compaction can keep up
- When the DB reaches several GB in size, compaction jobs start conflicting with each other
- Result: API server response times degrade to 5-6 seconds per query; eventually the cluster becomes unresponsive
- **Recovery requires stopping k3s, manually running a standalone Kine compaction, and restarting** — a procedure that cannot be performed on a deployed robot without a technician

This is not a hypothetical. It is a known, documented limitation of the SQLite/Kine architecture and has been reproduced in our environment.

**Additional failure modes:**
- SQLite cannot be used with multiple server nodes. If PhantomOS ever moves to a multi-node configuration per robot (e.g., separate compute for AI inference), k3s would require a full datastore migration.
- k3s ships with opinionated defaults (Flannel, Traefik, local storage provisioner) that add footprint and complexity. Disabling them requires explicit configuration — they don't just disappear.
- k3s is Rancher/SUSE's product. The roadmap and release cadence are controlled by an external vendor with commercial priorities.

**Note on k3s with embedded etcd:** k3s does support switching to embedded etcd, but this requires explicitly initializing a new cluster in HA mode. The etcd path in k3s still runs through Kine as an abstraction layer — the same layer that caused the compaction failure. It is not equivalent to running etcd natively.

**Verdict: Eliminated.** k3s is an excellent distribution for development clusters, CI/CD environments, and simple edge deployments where the DB failure mode is recoverable. A robot in a warehouse is not that environment. A DB failure that requires manual recovery is a field support incident. We cannot accept that risk.

---

## Option 4: k0s

### What it is
k0s is a lightweight Kubernetes distribution from Mirantis. Like k3s, it packages Kubernetes as a single binary. Unlike k3s, it defaults to etcd as its cluster state store for multi-node deployments and uses etcd via Kine only for the single-node SQLite path (which we would explicitly not use). It has a clean separation between the control plane and worker plane, ships without opinionated networking or ingress defaults, and runs on any Linux distribution including Ubuntu.

### How it addresses every failure mode above

| Constraint | How k0s handles it |
|---|---|
| Motor controller isolation | Full Kubernetes CPU Manager support with static policy. Control plane / worker plane separation means orchestration overhead is cleanly partitioned. |
| Offline-first | Self-contained single binary, no cloud control plane required. Works identically with or without connectivity. |
| Single-node per robot | Designed for this. Control plane and worker can run on the same node. |
| Ubuntu LTS compatible | Yes. No OS constraints. Installs as a binary + systemd service. |
| Production longevity | etcd is the Kubernetes production standard. Predictable performance, proven compaction, no SQLite growth risk. |
| CPU isolation + pinning | Kubernetes CPU Manager static policy supported. isolcpus kernel parameter + Guaranteed QoS pods gives full RT isolation. |

### Known tradeoffs

- **Binary size:** k0s is 160-300MB vs k3s at 50-100MB. On a Jetson Thor running a full AI stack, this is negligible.
- **Smaller community than k3s:** k3s has more community resources, Stack Overflow answers, and third-party integrations. k0s is growing rapidly but k3s has more ecosystem depth. Mitigation: our use case is straightforward — single-node, GitOps deployment, ArgoCD. We are not doing anything exotic.
- **No built-in ingress:** k0s ships without Traefik or any ingress controller. For PhantomOS this is a feature, not a gap — we use host networking where latency matters and don't need ingress complexity.

**Verdict: Selected.**

---

## Summary

| Distribution | Eliminated? | Primary Reason |
|---|---|---|
| KubeEdge | ✗ Yes | Requires cloud control plane. Robots must be autonomous. |
| MicroShift | ✗ Yes | RHEL-only. PhantomOS is Ubuntu LTS. Migration cost not justified. |
| k3s | ✗ Yes | SQLite/Kine failure mode reproduced in our environment. Unrecoverable in the field. |
| **k0s** | **✓ Selected** | etcd backend, Ubuntu compatible, offline-first, CPU isolation support. |

---

## Open Question for Architecture Discussion

The one remaining question before implementation: **k0s control plane placement on Jetson Thor.**

Jetson Thor has a mix of ARM CPU cores and GPU. The k0s control plane (etcd + API server + controller manager) needs to be pinned to specific CPU cores that do not overlap with:
- The motor controller's isolated cores (`isolcpus`)
- The AI inference cores (positronic control, DMA.video)

This CPU budget needs to be mapped out against the Thor hardware spec before finalizing the k0s deployment config. This is the first deliverable of the k3s architecture design task (3d, target Apr 10).