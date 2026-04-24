# Architecture Decision: ArgoCD Topology and Fleet GitOps Strategy

**Status**: Accepted
**Date**: 2026-04-15
**Decision**: Central ArgoCD on AWS, robots run plain k0s as registered target clusters
**Authors**: Siddhant M, discussed in POC sessions A–E

---

## Executive Decision

Run **one ArgoCD instance on AWS** that manages **N robots as registered target clusters**. Robots run plain k0s with their workloads only — no per-robot ArgoCD. Tailscale carries the AWS-to-robot control traffic. Git remains the source of truth; the gitops repo structure and Terraform bootstrap module we built during the POC carry over unchanged, with the only difference being the cluster the Terraform module targets (one AWS control plane, not N robot clusters).

This document captures every comparison and consideration that led to this choice, including the alternatives we rejected and why.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Architecture Options Overview](#architecture-options-overview)
3. [Option A: Per-Robot ArgoCD (What the POC Built)](#option-a-per-robot-argocd-what-the-poc-built)
4. [Option B: Central ArgoCD on AWS (Recommended)](#option-b-central-argocd-on-aws-recommended)
5. [Full Comparison Tables](#full-comparison-tables)
6. [Connectivity and Offline Analysis](#connectivity-and-offline-analysis)
7. [Container Image Distribution (Orthogonal to ArgoCD Choice)](#container-image-distribution-orthogonal-to-argocd-choice)
8. [AWS's Potential Roles](#awss-potential-roles)
9. [Fleet Management and Observability](#fleet-management-and-observability)
10. [Failure Modes](#failure-modes)
11. [Migration Path from the POC](#migration-path-from-the-poc)
12. [What Transfers As-Is](#what-transfers-as-is)
13. [Open Questions](#open-questions)
14. [Appendix: POC Session Summary](#appendix-poc-session-summary)

---

## Problem Statement

PhantomOS runs on Phantom humanoid robots. Each robot is a full edge compute node with CPU isolation for real-time work, multiple private container images, and operational needs for camera pipelines, authentication services, and episode upload. The fleet will grow from one robot to many, potentially dozens. Connectivity is expected to be "mostly online with intermittent gaps" — not permanently air-gapped, not continuously online.

We need a deployment and configuration management strategy that:

- Treats configuration as code (git as source of truth)
- Supports per-robot customization (different cameras, different calibration, different robot-specific env vars)
- Scales to a fleet with acceptable operational overhead
- Tolerates intermittent connectivity without operator intervention
- Allows rollback and auditability
- Provides visibility into what each robot is running and whether it matches intent
- Works with existing CI (CircleCI builds images) and existing infrastructure (Tailscale for remote access)

The POC built a per-robot ArgoCD model on `ch4` (Jetson-class test box) to prove the GitOps loop end-to-end. That POC worked, but raised the architectural question of whether ArgoCD should live on each robot or centrally on AWS. This document answers that question.

---

## Architecture Options Overview

At a high level, two topologies exist for running ArgoCD against a fleet of Kubernetes clusters:

```
OPTION A — ArgoCD on each robot (what the POC built)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  Robot: arg  │   │  Robot: blt  │   │  Robot: cpr  │
│  ┌────────┐  │   │  ┌────────┐  │   │  ┌────────┐  │
│  │ ArgoCD │  │   │  │ ArgoCD │  │   │  │ ArgoCD │  │
│  └───┬────┘  │   │  └───┬────┘  │   │  └───┬────┘  │
│      │       │   │      │       │   │      │       │
│  workloads   │   │  workloads   │   │  workloads   │
└──────┼───────┘   └──────┼───────┘   └──────┼───────┘
       │                  │                  │
       └──────────────────┼──────────────────┘
                          │ pull from git (each robot pulls independently)
                          ▼
                    git repo (manifests)

OPTION B — Central ArgoCD on AWS (recommended)
                    git repo (manifests)
                          │
                          ▼
                  ┌──────────────┐
                  │   AWS ArgoCD │
                  │  watches git │
                  │  manages N   │
                  │  clusters    │
                  └──┬────┬────┬─┘
                     │    │    │   (push reconciliation via Tailscale)
                     ▼    ▼    ▼
                  ┌──┐  ┌──┐  ┌──┐
                  │ar│  │bl│  │cp│   Each robot: plain k0s, no ArgoCD
                  │g │  │t │  │r │   workloads run as usual
                  └──┘  └──┘  └──┘
```

The choice between them is not about whether GitOps works — both work. It is about **where the control plane lives**, **how operational work scales with fleet size**, and **how intermittent connectivity is handled**.

---

## Option A: Per-Robot ArgoCD (What the POC Built)

### How it works

Every robot runs its own ArgoCD instance inside its own Kubernetes cluster. Each ArgoCD polls the gitops repo directly, compares the manifests in git to the state in its own cluster, and reconciles. There is no central coordinator — each robot is autonomous.

The POC implemented this topology. `ch4` runs its own ArgoCD at `https://100.75.41.101:30443`, pulls from `github.com/foundationbot/Phantom-OS-KubernetesOptions`, and reconciles the argentum workloads locally. Terraform installs ArgoCD on the robot's cluster as the bootstrap step.

### Strengths

**True autonomy per robot.** If a robot is offline for a month, its ArgoCD keeps its cluster in whatever state git was in at the last successful pull. No central controller needs to be reachable for the cluster to stay functional. Local controllers (Deployments, StatefulSets, ReplicaSets) keep pods healthy regardless of whether ArgoCD can reach git.

**No dependency on cloud infrastructure.** If AWS is down or the robot has no path to AWS, nothing on the robot is affected. The robot's ArgoCD just keeps enforcing the last-known-good state from its local git clone cache.

**Simpler security model for the cluster.** The robot's Kubernetes API does not need to be reachable from outside the robot. No inbound traffic to the robot's kube-apiserver. ArgoCD only needs outbound internet to reach git.

**No "blast radius" from central failure.** If one robot's ArgoCD misconfigures or crashes, only that robot is affected. A centralized misconfiguration could cause a fleet-wide incident.

### Weaknesses

**Operational overhead scales linearly with fleet size.** Each robot has its own ArgoCD instance to install, upgrade, patch, monitor, authenticate to, and troubleshoot. N robots means N ArgoCDs. Upgrading ArgoCD across the fleet means a rolling upgrade across every robot. Rotating ArgoCD credentials means rotating N times.

**No single pane of glass.** There is no native way to see "what is every robot running right now?" without writing custom aggregation tooling. Each robot's ArgoCD only knows about its own cluster. Answering questions like "is argentum on the same operator-ui version as bolt?" requires external fleet-wide telemetry.

**No central place to trigger or observe deploys.** Pushing a gitops change and then wanting to know "did it actually land on robot N?" requires either logging into each robot's ArgoCD UI or setting up external monitoring. A fleet-wide emergency patch requires verifying it landed in N places.

**Resource overhead on each robot.** ArgoCD's full stack is roughly 500m CPU and 1–2 GiB RAM at rest (7 pods: application-controller, applicationset-controller, server, repo-server, redis, dex, notifications). On a 14-core test box like ch4 this is tolerable; on tighter hardware it is not free. More importantly, every robot is now running software that has nothing to do with its actual job (driving the robot) — pure overhead.

**Each robot independently authenticates to the git repo.** The POC used a read-only SSH deploy key initially and switched to HTTPS anonymous after the repo was made public. With many robots, each needs credentials. If the repo is private, N robots means N credential endpoints to manage.

**Drift between robots is harder to detect.** Because each ArgoCD operates independently, a robot that has been offline for a week is silently running stale config. There is no cluster-registry that knows "bolt has not synced since 2026-04-01, investigate." You have to build that observation layer yourself.

### When Option A is the right choice

- Air-gapped or near-air-gapped robots that genuinely cannot rely on central connectivity
- Fleet size of one or two, where the overhead savings of centralization do not outweigh the simplicity of autonomy
- Compliance contexts where the robot cannot have inbound access from cloud infrastructure at all (even via Tailscale)
- When the robots are operated by completely different teams with no shared control plane

None of these apply to the current PhantomOS plan.

---

## Option B: Central ArgoCD on AWS (Recommended)

### How it works

One ArgoCD instance runs in AWS (on EKS, or on an EC2-hosted k0s, or on any Kubernetes platform). Every robot's k0s cluster is registered as a target cluster in this central ArgoCD. The gitops repo structure we built (`manifests/base/` + `manifests/robots/<name>/`) stays identical. Applications in this central ArgoCD point their `destination.name` at the registered robot clusters rather than at `https://kubernetes.default.svc` (which is local).

When a gitops commit lands, the central ArgoCD reconciles against every registered cluster in parallel. When a robot is offline, its cluster registration shows "unreachable" and reconciliation is deferred. When the robot comes back online, ArgoCD re-establishes the connection and catches up.

Traffic flows **from AWS to the robot** — ArgoCD's application-controller connects outbound to each robot's kube-apiserver. Tailscale provides the network path; the robot's API server is reachable only over the tailnet, not over the public internet.

### Strengths

**One place to see everything.** A single ArgoCD UI shows every robot's state, sync status, health, drift, and history. Answering "is argentum on the same operator-ui version as bolt?" is a single glance, not a spreadsheet exercise.

**Operational cost stays O(1) as the fleet grows.** Upgrading ArgoCD, rotating credentials, changing sync policies, managing AppProjects — all of it happens once, centrally, and applies to the whole fleet. Adding robot N+1 is "register a kubeconfig, add a directory to the gitops repo" — no ArgoCD install per robot.

**ApplicationSet is a natural fit.** With central ArgoCD, an ApplicationSet with a Git Generator can read `manifests/robots/*/` and auto-generate one Application per robot, each targeting the matching registered cluster. Onboarding a new robot becomes zero-YAML — create the overlay directory, register the kubeconfig, done.

**Fleet-wide rollout and observation in one pipeline.** Pushing a new operator-ui tag to the argentum overlay, verifying the rollout, rolling back if it fails, and moving on to the next robot — all observable and controllable from one pane. Canary patterns (deploy to argentum first, then bolt, then the rest) become straightforward ApplicationSet configurations.

**Less software running on each robot.** The robot runs k0s and its workloads — nothing else. No ArgoCD stack consuming CPU and memory. No git-pulling process competing with real-time work for cycles. The robot does its job; the control plane lives elsewhere.

**Better audit trail.** One ArgoCD's event log shows every reconciliation across the fleet. Per-robot ArgoCD spreads this across N systems, making post-incident reconstruction harder.

**Central credentials management.** One set of git credentials, one set of robot-cluster credentials (kubeconfigs as Kubernetes Secrets in ArgoCD's namespace), one set of RBAC policies. Managed via Terraform or a secret manager, not scattered across robots.

### Weaknesses

**Requires AWS → robot connectivity.** The central ArgoCD needs to reach each robot's kube-apiserver to reconcile. If the robot is offline, reconciliation cannot happen for that robot until connectivity is restored. This is where Tailscale earns its keep — every robot is a tailnet node, and AWS ArgoCD reaches robots over the tailnet. When a robot is offline, its tailnet node disappears and ArgoCD marks the cluster unreachable.

**AWS ArgoCD is now a critical path.** If the central ArgoCD is down (AWS outage, bad config push, upgrade failure), no fleet-wide changes can flow. Workloads already running on robots stay running — Kubernetes itself does not need ArgoCD — but you cannot push updates or roll back until ArgoCD is restored. Mitigations: standard monitoring, standard HA for ArgoCD, periodic backup of ArgoCD's etcd state.

**Inbound exposure of robot kube-apiservers.** Every robot's Kubernetes API must be reachable by central ArgoCD. This is not "open to the internet" — it is "reachable via Tailscale ACL-constrained tailnet" — but it is a surface area that per-robot ArgoCD does not have. Proper Tailscale ACLs (central-argocd node can talk to `tag:robot` on port 6443) and kube-apiserver RBAC mitigate this.

**Config lag for offline robots.** If a robot is offline during a deploy, the deploy does not reach it until the robot returns. This is not a flaw — it is correct behavior — but it is worth naming. With per-robot ArgoCD the same lag exists (offline robot cannot pull from git either), so this is not actually a relative disadvantage.

### When Option B is the right choice

- Fleets of more than one or two robots with shared operational ownership
- Mostly-online robots with intermittent disconnections (the robot is online most of the day but not necessarily at the instant a deploy happens)
- Teams that need visibility across the fleet without building custom aggregation tooling
- Organizations with existing cloud infrastructure and security posture that can support a central control plane
- Shared credentials and RBAC models (one team owns deploys across robots)

This matches PhantomOS.

---

## Full Comparison Tables

### Operational cost

| Dimension | Option A (per-robot) | Option B (central) |
|---|---|---|
| ArgoCD installs | N (one per robot) | 1 |
| ArgoCD upgrades | N rolling upgrades | 1 upgrade |
| Credential rotation | N times | 1 time |
| Observability across fleet | Requires custom aggregation | Native |
| Resource overhead per robot | ~0.5 CPU + 1-2 GiB RAM | 0 |
| Onboarding a new robot | Install ArgoCD + register repo + apply root | Register kubeconfig + add directory |
| RBAC management | N separate policies or sync tooling | 1 policy |

### Connectivity dependencies

| Scenario | Option A | Option B |
|---|---|---|
| Robot has internet, everything normal | Works | Works |
| Robot briefly offline (minutes) | Current state preserved; next sync catches up | Same: cluster marked unreachable; next reconcile catches up |
| Robot offline for days | Same as above | Same as above |
| AWS ArgoCD down | No effect on robots | No fleet-wide changes until restored (workloads keep running) |
| Git repo unreachable | No syncs possible fleet-wide | No syncs possible fleet-wide |
| DockerHub unreachable | New image pulls fail (cached work) | New image pulls fail (cached work) |
| Tailscale down | No effect (robots pull from git directly) | Central ArgoCD cannot reach robots; marks them unreachable |

### Failure blast radius

| Failure | Option A | Option B |
|---|---|---|
| Bad manifest pushed to git | Every ArgoCD tries to apply, every robot fails the same way | Central ArgoCD applies to every registered cluster; same outcome |
| ArgoCD misconfiguration | Affects one robot | Affects fleet |
| ArgoCD bug in new version | Affects robots upgraded to that version | Affects fleet |
| Robot-specific bad config in overlay | Affects that robot only | Affects that robot only |
| AWS region outage | No effect on robots | No deploys flow until region recovers |
| Tailscale outage | No effect (git is public path) | No deploys flow; existing workloads unaffected |

### Implementation complexity

| Aspect | Option A | Option B |
|---|---|---|
| Initial setup | Terraform per robot | One Terraform in AWS + register robots |
| Gitops repo structure | `manifests/base/` + `manifests/robots/<name>/` | Identical |
| Application CRs | One per robot, stored on robot's ArgoCD | One per robot, central; easier to template via ApplicationSet |
| Secrets (image pull, etc.) | Managed per cluster | Managed per cluster (same) |
| Git credentials | Per robot | Central |
| Networking | Robot → internet (outbound only) | AWS → robot via Tailscale (inbound to robot kube-api over tailnet) |

---

## Connectivity and Offline Analysis

A key part of the discussion was understanding what "offline" actually breaks, because intuition about offline robots is often wrong. Here is the real analysis.

### Two separate flows, commonly conflated

**Flow 1 — configuration files (manifests).** The gitops repo pushes YAML. ArgoCD reads YAML from git. The YAML is small. The bandwidth cost is trivial. This flow is what people mean when they say "push config to the robot."

**Flow 2 — container images.** Application code changes mean new images. New images must be pulled from a registry (DockerHub in our case) to the robot's containerd local storage before the pod can start. Images are large (hundreds of MB each). This flow is what actually fails on bad connectivity.

The GitOps architecture debate (where ArgoCD lives) is entirely about Flow 1. Flow 2 is identical regardless of where ArgoCD lives — the robot's kubelet pulls from a registry, and no ArgoCD topology changes that fact.

### What needs internet today, by action

| Change type | Internet needed? | Why |
|---|---|---|
| Tweak a `resources.requests.cpu` value | No | Manifest change, no new image |
| Change an env var | No | Same |
| Scale replicas | No | Same |
| Add a new ConfigMap | No | Same |
| Bump `newTag` to a new image SHA | Yes, at least once | Robot must pull the new image |
| Delete a pod (ArgoCD selfHeal recreates) | No | Image already cached |
| Robot reboot after N weeks of image GC | Maybe | containerd may have evicted unused images |
| Fresh robot coming online for first time | Yes | All images must be pulled |

### What containerd caches and for how long

Once kubelet successfully pulls `foundationbot/argus.operator-ui:abc123` to the robot, containerd stores the image layers on disk. Subsequent pod restarts, deletions, recreations, and even node reboots do not re-pull — they reuse the cached layers.

The cache is evictable. containerd has garbage collection policies; by default it prunes unused images when disk pressure hits a threshold. A robot that does not restart pods for weeks can lose cached images to GC.

Practical implications:

- A robot that regularly runs its workloads retains those images in cache indefinitely
- A robot that runs for a long time and then gets a new image tag needs internet exactly once (the first pull)
- A fresh robot has to pull everything from scratch the first time it comes online
- A robot that has been off for months may need a large re-pull when it returns

None of this is affected by where ArgoCD runs.

### The "air-gapped robot" scenario

If a robot truly goes weeks without any internet connectivity, and during that time needs a config change **and** new images, neither ArgoCD topology helps. You would need:

1. A **local registry on the robot** (Zot, `registry:2`, or in-cluster) that holds all images the robot might need
2. A **sync job** that pulls from upstream (DockerHub / ECR) when the robot is online and mirrors locally
3. Manifests that reference `localhost:5000/foundationbot/...` instead of `foundationbot/...`
4. A **local git mirror** if you do not want to rely on the robot reaching the internet to pull manifests

This is a significantly more complex setup and should only be built when the connectivity model actually requires it. For robots in operator facilities with WiFi, this is overkill.

We chose to NOT pursue this path because the real connectivity model is "mostly online with gaps," not "permanently air-gapped."

### The "intermittent connectivity" reality check

For robots that are online most of the time but drop offline for minutes or hours:

- **Central ArgoCD**: robot tailnet node disappears; ArgoCD marks cluster unreachable; reconciles when it returns. No workload impact.
- **Per-robot ArgoCD**: ArgoCD fails to pull from git; stays on last-known-good manifest; reconciles when connectivity returns. No workload impact.

Both handle this correctly. The difference is operational visibility: central ArgoCD shows you the fleet-wide connectivity state in one place; per-robot ArgoCD requires you to check each robot individually.

### Why "central ArgoCD is worse for offline" is wrong

A common initial intuition is that central ArgoCD fails during robot outages while per-robot ArgoCD keeps working. This is a misunderstanding of how both modes behave.

- Per-robot ArgoCD during an outage: ArgoCD on the robot fails to fetch from git. Cluster stays on last known state. Kubernetes controllers (Deployment, ReplicaSet) keep pods running. No syncs happen.
- Central ArgoCD during a robot outage: Central ArgoCD fails to reach the robot over Tailscale. Cluster marked unreachable. Kubernetes controllers on the robot keep pods running. No syncs happen.

The observable behavior during an outage is identical: existing workloads run, new changes are deferred until connectivity returns. Central ArgoCD is not worse here; it is equivalent.

The one genuine asymmetry is **AWS control-plane failure**. If AWS goes down, central ArgoCD cannot deploy to any robot. If per-robot ArgoCD is in use, AWS going down has zero effect. But this is mitigated by standard AWS availability practices (multi-AZ, ArgoCD HA, backups) and, critically, workloads on the robot are unaffected regardless. The worst case is "no new deploys for the duration of an AWS outage," which is acceptable.

---

## Container Image Distribution (Orthogonal to ArgoCD Choice)

Image distribution is a separate axis from ArgoCD topology. You can combine any image strategy with any ArgoCD topology. Listing the options for completeness.

### Option I1: DockerHub directly

Current model. CircleCI builds and pushes to `hub.docker.com/foundationbot/*`. Robots pull from DockerHub with a per-namespace `dockerhub-creds` image pull secret. Multi-arch manifests cover amd64 and arm64.

**Pros**: zero infrastructure to manage beyond CI config.
**Cons**: DockerHub rate limits for anonymous pulls; single credential for the whole fleet; no audit trail per robot; DockerHub availability is a dependency.

### Option I2: Amazon ECR (public or private)

CircleCI builds and pushes to `<account>.dkr.ecr.<region>.amazonaws.com/foundationbot/*`. Robots pull from ECR. IAM-based auth allows per-robot credentials. ECR replication handles regional distribution.

**Pros**: IAM-scoped per-robot credentials, audit logs, replication, better rate limits for heavy fleets.
**Cons**: Storage cost per GB, egress cost to robots, one more AWS service in the stack.

### Option I3: In-robot registry (Zot or similar)

A small registry runs on each robot, bound to `localhost:5000`. All manifests reference `localhost:5000/foundationbot/*`. A sync process pulls from upstream (DockerHub or ECR) to the local registry when online.

**Pros**: Robot can run entirely offline after initial sync; update sizes are only the delta; very resilient to connectivity gaps.
**Cons**: Additional running service on every robot; disk space; a sync job to maintain; manifests must be rewritten (via Kustomize `images:` block) to reference local registry.

### Option I4: Pre-seeded images in robot image

All images the robot will ever need are baked into the robot's OS image or pre-pulled during provisioning. `imagePullPolicy: IfNotPresent` everywhere.

**Pros**: Zero runtime pull dependency; robot can operate indefinitely offline after provisioning.
**Cons**: Any image update requires shipping a new robot image or an update bundle; no granular incremental updates.

### Recommendation

Start with **Option I1 (DockerHub)** for the POC and initial fleet. Move to **Option I2 (ECR)** when any of the following becomes true:

- DockerHub rate limits become a problem at scale
- Per-robot credential scoping is required for compliance
- The team wants audit logs of which robot pulled which image when

Consider **Option I3 (in-robot registry)** only if the fleet grows to include robots that genuinely operate offline for extended periods. This is additional infrastructure complexity and should be deferred until needed.

**Option I4 (pre-seeded)** is only appropriate for tightly controlled, low-update-frequency deployments — probably not PhantomOS.

Image distribution choice and ArgoCD topology choice are independent. All four image options work with both Option A and Option B ArgoCD topologies.

---

## AWS's Potential Roles

AWS can play several distinct roles in the architecture. These are additive, not mutually exclusive.

### Role 1: Host the central ArgoCD

EKS is the obvious home. EC2 running k0s or kind is viable for cost savings. ArgoCD itself has modest resource needs (roughly 2 vCPU and 4 GiB RAM for a comfortable single-instance deployment). This is the primary AWS role in Option B.

### Role 2: Image registry (ECR)

Discussed above as Option I2. Can coexist with DockerHub (some images from each) or replace DockerHub entirely.

### Role 3: Fleet observability

Prometheus federation, Grafana, Loki for log aggregation — the standard observability stack. Robots push metrics and logs to AWS-hosted endpoints (with short-term local buffering for offline periods). This answers "is robot N healthy, what is its CPU pressure, what is it running?" at the fleet level.

### Role 4: Secrets management

AWS Secrets Manager or Parameter Store for centrally managing credentials that robots need (DockerHub creds, IoT certs, per-robot AWS credentials). With External Secrets Operator on each robot, secrets sync from AWS into the robot's Kubernetes Secrets.

### Role 5: IoT backplane (already in use)

The existing IoT endpoint (`c4r067w5awayr.credentials.iot.us-west-1.amazonaws.com` in `manifests/base/nimbus/eg-jobs.yaml`) shows AWS IoT Core is already part of the design for nimbus uploads. This is independent of the gitops decision.

### Role 6: Backup and disaster recovery

ArgoCD's state lives in its own cluster's etcd. Backing this up to S3 (via velero or similar) provides recovery if the central ArgoCD is lost.

### Recommendation

For the initial central-ArgoCD rollout:

- **Start with Role 1 only.** Put ArgoCD on EKS or a simple EC2-hosted k8s. Everything else can wait.
- **Add Role 3 (observability) early** — you will want fleet-wide metrics once you have more than two robots. Prometheus federation from robot Prometheus instances to an AWS-hosted one is the standard pattern.
- **Role 2 (ECR), Role 4 (Secrets Manager), Role 5 (IoT, already in use), Role 6 (backup)** — add as needed. Each is a weeks-level project, not a session-level one.

---

## Fleet Management and Observability

Even with central ArgoCD, some fleet-level concerns need explicit tooling.

### Per-cluster state visibility

Central ArgoCD's UI shows every registered cluster and its Applications. For each Application you see Sync status (Synced / OutOfSync / Unknown), Health (Healthy / Progressing / Degraded / Missing), last sync time, sync history. This covers the "what is each robot running" question natively.

### Fleet-wide metrics

Central ArgoCD shows you ArgoCD's view of each cluster. It does not show you cluster-internal metrics like CPU pressure, disk usage, pod restart rates, or application-specific health. For that, you want:

- **Prometheus on each robot** scraping kube-state-metrics, node-exporter, and custom application metrics
- **Prometheus in AWS** federating from each robot's Prometheus
- **Grafana in AWS** dashboards for fleet-wide views

### Logs aggregation

Similarly, application logs need to flow from robots to a central store. Loki or CloudWatch Logs, ingested via Vector or Promtail running on each robot.

### Fleet-wide alerting

Alertmanager rules against the federated Prometheus. Alerts for:

- A robot has not synced from ArgoCD in > 1 hour
- A robot's cluster is marked unreachable for > 5 minutes
- A robot's disk is > 80% full
- A robot's pod restart rate is elevated
- A robot's operator-ui is serving HTTP 5xx

### ApplicationSet for fleet definition

ApplicationSet is an ArgoCD CR that generates multiple Applications from a template. With a **Git generator** pointed at `manifests/robots/*/kustomization.yaml`, an ApplicationSet can produce one Application per directory:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: phantomos-fleet
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git
        revision: main
        directories:
          - path: manifests/robots/*
  template:
    metadata:
      name: 'phantomos-{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git
        targetRevision: main
        path: '{{path}}'
      destination:
        name: '{{path.basename}}'  # matches registered cluster name
        namespace: default
      syncPolicy:
        automated: { prune: true, selfHeal: true }
```

With this in place, onboarding robot `bolt`:

1. `cp -r manifests/robots/argentum manifests/robots/bolt` and tweak
2. `argocd cluster add bolt-context --name bolt` to register its kubeconfig
3. Push

The ApplicationSet picks up the new directory, generates a `phantomos-bolt` Application targeting the `bolt` cluster, and starts syncing. Zero per-robot YAML to author in the gitops repo beyond the overlay itself.

This pattern is a significant operational win for fleet management and is natural in Option B. In Option A (per-robot ArgoCD), each robot's ArgoCD would need its own Application CR authored, applied, and maintained.

---

## Failure Modes

Explicit enumeration of what can go wrong and how the two topologies handle it.

### 1. Bad manifest pushed to git

**Option A**: each robot's ArgoCD tries to apply, fails health checks, `OutOfSync` or `Degraded` across the fleet. Rollback via git revert; each robot re-pulls and recovers on its own schedule.

**Option B**: central ArgoCD tries to apply to every cluster; same failure mode, same rollback path. The advantage: you see the failure in one place immediately, and you can use ApplicationSet rollout strategies (e.g., RollingSync) to only hit a subset of robots first.

Central ArgoCD is better here because of visibility and rollout control.

### 2. ArgoCD version upgrade breaks something

**Option A**: upgrade fails on some robots, succeeds on others; fleet is now running mixed ArgoCD versions; hard to diagnose. Must roll back per robot.

**Option B**: upgrade happens once centrally; either it works or it doesn't. If it fails, the fleet is unchanged because the existing ArgoCD was not touched on each robot (there isn't one). Rollback is a single Terraform revert.

Central ArgoCD is meaningfully better here.

### 3. Network partition isolating one robot

**Option A**: that robot's ArgoCD cannot reach git; stays on last state; no impact to workloads.

**Option B**: central ArgoCD cannot reach that robot; cluster marked unreachable; stays on last state; no impact to workloads.

Equivalent in observable behavior. Central ArgoCD has visibility into which robots are partitioned, per-robot ArgoCD does not.

### 4. Git repo unavailable (GitHub outage)

**Option A**: every robot's ArgoCD fails to pull; fleet-wide sync halt; workloads unaffected.

**Option B**: central ArgoCD fails to pull; fleet-wide sync halt; workloads unaffected.

Equivalent.

### 5. AWS region hosting central ArgoCD goes down

**Option A**: unaffected.

**Option B**: no deploys possible until region recovers. Workloads on robots unaffected. Mitigation: multi-region ArgoCD, or accept the outage window as a known risk.

Option A wins here, but the risk is mitigable and the cost of mitigation (multi-region AWS ArgoCD) is manageable.

### 6. Image registry (DockerHub or ECR) unavailable

**Option A**: new image pulls fail; existing cached images still work.

**Option B**: same behavior.

Equivalent. Independent of ArgoCD topology.

### 7. Tailscale outage

**Option A**: robots still pull from GitHub over the public internet (not via tailnet). Unaffected.

**Option B**: central ArgoCD cannot reach robots. Fleet-wide sync halt until tailscale recovers. Workloads unaffected.

Option A wins here, but only if robots have public internet access for git pulls that does not route through tailscale. If tailscale is the only outbound path (unlikely), Option A also fails.

### 8. Rogue commit pushed by a compromised credential

**Option A**: every robot's ArgoCD auto-syncs the bad commit. Fleet-wide impact. Rollback via revert.

**Option B**: central ArgoCD auto-syncs to every cluster. Fleet-wide impact. Rollback via revert. ApplicationSet rolling strategies can limit blast radius if configured (e.g., argentum syncs first, rest wait).

Central ArgoCD offers better tools to limit blast radius here.

### 9. One robot's kubeconfig expires or is rotated

**Option A**: the robot's ArgoCD is unaffected (it does not use its own kubeconfig against itself; it uses in-cluster credentials).

**Option B**: central ArgoCD cannot reach that specific robot; cluster marked unreachable until kubeconfig is refreshed in ArgoCD's secret store. Other robots unaffected.

Option A has no analog of this failure. Option B needs credential rotation tooling — real operational concern but solvable with standard practices.

### Summary of failure mode comparison

Central ArgoCD is better for: bad manifest visibility, upgrade safety, rollout control, blast radius limitation, audit trail.

Per-robot ArgoCD is better for: tolerating AWS outages, tolerating tailscale outages, not requiring credential rotation for a central-to-robot link.

The asymmetric AWS failure concern is real but manageable. The operational wins of central ArgoCD are larger and recur every day; the AWS outage concern is rare and mitigable.

---

## Migration Path from the POC

The POC currently has ArgoCD running on ch4. Moving to central ArgoCD is straightforward because the gitops repo structure was designed for either topology.

### Step 1 — Stand up central ArgoCD

Target: an EKS cluster, or a small EC2-hosted k8s, or kind on a laptop for initial testing.

Run the existing Terraform module pointed at the new cluster:

```bash
cd terraform
terraform apply -var='kubeconfig=~/.kube/central-argocd'
```

The module installs ArgoCD + applies the root Application. Same code, different target.

### Step 2 — Register ch4 as a target cluster

On central ArgoCD, register ch4's kubeconfig:

```bash
export KUBECONFIG=~/.kube/central-argocd
argocd cluster add ch4-context --name argentum
```

This creates a `cluster-*` Secret in the central ArgoCD's namespace with ch4's connection details. The cluster is now known as `argentum` (the robot name) inside central ArgoCD.

### Step 3 — Change Application destinations

Edit `gitops/apps/phantomos-argentum.yaml` and `gitops/apps/hello.yaml`:

```yaml
# Before
destination:
  server: https://kubernetes.default.svc  # local to ArgoCD's cluster
  namespace: default

# After
destination:
  name: argentum  # registered robot cluster name
  namespace: default
```

Commit and push. The central ArgoCD reconciles; Applications now target the registered `argentum` cluster over Tailscale.

### Step 4 — Remove ArgoCD from ch4

Once central ArgoCD is happily managing ch4, tear down ch4's ArgoCD:

```bash
export KUBECONFIG=~/.kube/ch4-config
kubectl delete application --all -n argocd --cascade=foreground
kubectl delete namespace argocd
kubectl get crd -o name | grep argoproj | xargs kubectl delete
kubectl get clusterrole,clusterrolebinding -o name | grep argocd | xargs kubectl delete
```

The robot now runs plain k0s with its workloads. Central ArgoCD has taken over.

### Step 5 — Add ApplicationSet for future robots

Replace the hand-authored `gitops/apps/phantomos-argentum.yaml` with an ApplicationSet that generates Applications from `manifests/robots/*/`. Future robots are added by creating the overlay directory and registering the cluster; no per-robot YAML needed in `gitops/apps/`.

### Step 6 — Add fleet observability

Prometheus federation from robots to AWS, Grafana dashboards, alerting rules. Out of scope for this document but worth naming.

### Rollback path

If central ArgoCD is not working, we can revert to per-robot ArgoCD in the same gitops repo. The overlay files do not change. Only the Application CRs need their destinations pointing back at `https://kubernetes.default.svc`, and each robot runs the Terraform module pointing at itself. This is the exact POC state. We can always go back.

---

## What Transfers As-Is

The POC work that carries over without modification:

**Manifests directory structure** — `manifests/base/{argus,dma-video,nimbus}/` with per-namespace `kustomization.yaml` files. Identical.

**Per-robot overlays** — `manifests/robots/argentum/` using `commonAnnotations`, `resources`, and `images` blocks. Identical. New robots get their own directories following the same pattern.

**App-of-apps pattern** — one root Application fanning out to children. The ApplicationSet version in Option B is an enhancement, not a replacement; the shape of the dependency graph is the same.

**Kustomize image pin mechanism** — `images: [{name: foundationbot/..., newTag: <sha>}]` in overlays. Identical. CI (CircleCI) updates `newTag` via `yq`; flow is the same whether the consuming ArgoCD is central or per-robot.

**Terraform module** — `terraform/main.tf` installs ArgoCD + applies root Application. Same module, different target cluster.

**GitOps repo public** — ArgoCD reads anonymously in either topology.

**DockerHub + `dockerhub-creds` secret** — each robot cluster still needs the image pull secret in each workload namespace. This is a robot-local concern, unchanged by ArgoCD topology.

**CircleCI build + update-gitops flow** — CircleCI builds images, an update-gitops step (in CircleCI config, per the workaround direction) bumps the tag in the overlay, ArgoCD picks it up. Same mechanism, same end-to-end timing, regardless of where ArgoCD runs.

**Tailscale** — already in use for ch4 access. Same transport for central-to-robot communication.

### What the POC discovered that is not in this doc but lives in memory

- Tegra kernel lacks `ip_set_hash_{ip,net}` modules; kube-router does not work. Solution: swap CNI to Flannel. Jetson robots need this; Intel robots do not.
- The full argentum stack as currently specified requires ~18 CPU; ch4 has 12.5 allocatable. Base manifests assume the robot's 20-core Intel machine. Per-environment overlays will be needed to deploy to smaller hardware.
- CircleCI's existing config builds multi-arch (amd64 + arm64) for at least argus.operator-ui. Other foundationbot repos' multi-arch status is not verified.
- The foundationbot org restricts GitHub Actions; workflow files added via user-created branches do not trigger. CircleCI is the path forward for CI-driven gitops updates.

---

## Open Questions

Items that this document does not answer and that need decisions before full production rollout.

**How are new robots provisioned?** The Terraform module installs ArgoCD on a cluster, but does not install k0s itself. Each robot needs k0s installed and its kubeconfig exported to wherever central ArgoCD runs. This can be automated (ansible, ignition, cloud-init) or manual. Decide scope.

**Where do per-robot secrets live?** `dockerhub-creds`, `iot-certs`, and any other per-namespace secrets currently live in each cluster's etcd. Options: keep as-is (manual creation per cluster), use External Secrets Operator with AWS Secrets Manager as backing store, use SOPS-encrypted secrets in git. This is a real operational decision worth its own design doc.

**Canary / staged rollout policy.** ApplicationSet supports RollingSync and RollingUpdate strategies. What is the policy? "argentum gets new versions first, if healthy for 24h, then bolt" is a typical pattern. Needs definition.

**Rollback automation.** Git revert is the base mechanism. Whether the team wants ArgoCD notifications auto-posting to Slack on sync failures, whether they want automatic revert triggers on health degradation, whether they want a dedicated rollback procedure — to be decided.

**Disaster recovery for central ArgoCD.** ArgoCD state in etcd must be backed up. Velero to S3, or equivalent. Not currently in place.

**Fleet-wide upgrade strategy for k0s itself.** k0s has autopilot controllers that can upgrade a cluster automatically. Should this be enabled? Staggered across the fleet?

**Workload identity to AWS services.** Nimbus uploads to S3 via IoT Core-issued credentials. This is one of several AWS integrations. Others may need IAM Roles for Service Accounts (IRSA) — which only works on EKS, not on k0s at the edge. Decide auth pattern.

**CPU sizing for non-argentum robots.** Future robots may have different hardware. The base manifests' CPU requests are sized for the argentum robot's 20 cores. Smaller robots need overlays that drop CPU requests. Document the sizing conventions.

**Motor controller integration with the cluster.** Motor controller runs as host systemd (by design, for real-time determinism). Pods that need to talk to it use `hostIPC: true` and `/dev/shm`. This is specified in the manifests but not yet tested on a real robot. First robot deployment will surface issues.

**eg-jobs with real IoT certs.** The iot-certs volume mount is currently commented out in `manifests/base/nimbus/eg-jobs.yaml`. First real deployment will require the Secret to be created and the volume uncommented.

---

## Appendix: POC Session Summary

The POC ran across five sessions and resulted in a working per-robot ArgoCD on ch4. Summary of what was built, referenced here for context.

### Session A — k0s on ch4

- Installed k0s v1.35.3 on a Jetson AGX Orin (arm64, Tegra kernel)
- Discovered Tegra kernel lacks ipset hash modules required by kube-router
- Swapped CNI to Flannel as the Tegra-compatible alternative
- Set up SSH key auth and NOPASSWD sudo for remote management
- Exported kubeconfig to local developer machine for cross-Tailscale kubectl access

### Session B — ArgoCD + gitops loop

- Installed ArgoCD via raw manifests, exposed via NodePort 30443
- Configured read-only SSH deploy key for the then-private gitops repo
- Created a hello nginx Application to prove git-push-to-deploy
- Measured: commit push to pod running in ~8 seconds after a hard refresh

### Session C — Fleet and per-robot layers

- Introduced `manifests/base/` + `manifests/robots/argentum/` Kustomize structure
- Added `commonAnnotations` on the argentum overlay (robot=argentum, fleet=phantomos)
- Introduced app-of-apps root Application in `gitops/root-app.yaml`
- Verified the full argentum stack syncs; discovered ch4's CPU capacity is insufficient for the default CPU requests (base manifests assume Intel 20-core robot)

### Session D — Source-repo to gitops-repo flow

- Demonstrated tag-bump flow: Kustomize `images:` block, change newTag, commit, ArgoCD reconciles
- Wrote a GitHub Actions workflow (`.github/workflows/update-gitops.yml`) for argus.operator-ui to automate tag bumps
- Discovered foundationbot org restricts GitHub Actions; workflow does not trigger
- Confirmed CircleCI is the supported CI path in the org; CircleCI-based equivalent of the workflow is the correct direction
- Demonstrated the tag-bump logic locally by running the `yq` + `git push` steps directly — ArgoCD reconciled within 8 seconds

### Session E — Terraform bootstrap

- Wrote Terraform module in `terraform/` that installs ArgoCD via the official Helm chart and applies the root Application
- Tested by tearing down the session B raw-manifest ArgoCD, cleaning up cluster-scoped leftovers (CRDs, ClusterRoles), and running `terraform apply` from a clean state — new Helm-managed ArgoCD came up and re-adopted the existing workloads via git

### What the POC did not cover

- Full dma-video camera pipeline with real cameras (requires privileged pod + USB + DMA shared memory — untested end-to-end)
- Motor controller shared-memory integration (untested)
- eg-jobs with real IoT certs and S3 uploads (cert volume mount currently commented out)
- Fleet deployment beyond one robot (ch4 only)
- Fleet observability stack
- Central-ArgoCD topology (this document recommends it; it has not been implemented yet)

---

## Summary

Central ArgoCD on AWS is the correct architecture for PhantomOS. The reasoning:

- Operational cost of N per-robot ArgoCDs grows unacceptably with fleet size
- Fleet visibility requires either central ArgoCD natively or custom aggregation tooling that would need to be built anyway
- Intermittent connectivity is handled equivalently by both topologies; the "central ArgoCD fails offline" intuition is wrong
- AWS outage is the one genuine asymmetric risk and is manageable with standard mitigations
- The gitops repo structure and Terraform module built during the POC transfer directly; only the cluster Terraform targets changes
- ApplicationSet on central ArgoCD makes onboarding new robots near-zero-effort

The POC work is not wasted. The manifests, overlays, Terraform, CircleCI-based CI flow, and Tailscale integration all carry over. Only the ArgoCD deployment topology changes, from "one per robot" to "one central, robots registered as targets."

Next concrete step when this decision is ratified: stand up central ArgoCD on a small AWS-hosted cluster, register ch4 as a target, migrate the existing Applications to point at the registered cluster, and verify end-to-end behavior. Once that works, plan real-robot provisioning and add the ApplicationSet pattern for multi-robot onboarding.
