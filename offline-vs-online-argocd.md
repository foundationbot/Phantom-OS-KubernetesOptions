# ArgoCD Topology: Offline (per-robot) vs Online (central on AWS)

**Decision: Online. One central ArgoCD on AWS, robots run plain k0s.**

The "offline" label is a bit misleading either way — both topologies keep running during connectivity outages; the difference is where the control plane lives.

---

## Side-by-side

| | **Offline** (per-robot ArgoCD) | **Online** (central ArgoCD on AWS) |
|---|---|---|
| **Where ArgoCD runs** | One instance per robot | One instance in AWS, robots are target clusters |
| **What robot needs at runtime** | Outbound to git | Tailscale reachable from AWS |
| **Control plane failure** | Per-robot — blast radius = 1 | Central — blast radius = fleet (but workloads unaffected) |
| **Operational cost as fleet grows** | Linear (N) | Constant (1) |
| **Fleet-wide visibility** | Build it yourself | Native, one pane |
| **Onboarding new robot** | Install ArgoCD + Terraform + Application CR | Register kubeconfig + add overlay directory |
| **Emergency patch across fleet** | Push to git, each robot picks up when online | Push to git, central ArgoCD fans out |
| **Robot-side resource cost** | ~0.5 CPU + 1-2 GiB RAM (7 pods) | Zero |
| **Credential management** | N sets of git creds | 1 set |
| **ArgoCD version drift across fleet** | Real risk (rolling upgrades are N operations) | Impossible (one instance) |
| **Tailscale outage** | No effect | No new deploys; workloads keep running |
| **AWS region outage** | No effect | No new deploys; workloads keep running |
| **Git outage** | Fleet-wide deploy pause | Same |

---

## Pros / Cons

### Offline (per-robot)

**Pros**
- Truly autonomous robots — no dependency on any cloud infra
- AWS outage = no impact on deploys (only real asymmetric advantage)
- Tailscale outage = no impact
- Smaller security surface on the robot (no inbound)

**Cons**
- No single pane of glass for fleet state
- Linear operational cost: upgrades, credentials, monitoring, debugging all happen N times
- Drift between robots is silent until someone notices
- Each robot runs software that has nothing to do with its job (driving the robot)
- Onboarding is high-friction

### Online (central on AWS)

**Pros**
- One UI, one credential set, one upgrade path, one rollout mechanism
- ApplicationSet auto-generates Applications from `manifests/robots/*/` — adding a robot is effectively zero-YAML
- Staged/canary rollouts across the fleet become natural
- Real audit trail of fleet-wide activity
- Robot runs only what it needs to run

**Cons**
- Needs AWS → robot connectivity (Tailscale handles it; already in place)
- AWS ArgoCD is now a critical piece of infra that needs HA/backups
- Inbound path to robot kube-api over Tailscale — bigger surface than pure-outbound (mitigated by Tailscale ACLs)
- Robot-specific kubeconfigs in central ArgoCD need lifecycle management (rotation, expiry)

---

## The intuition that gets this wrong

> "Per-robot ArgoCD is better for offline because each robot can self-reconcile."

This sounds right but isn't, in practice:

- When a robot is **briefly offline**, both topologies behave identically: last-known-good state keeps running, new changes deferred until connectivity returns.
- When a robot is **offline for days**, same behavior — per-robot ArgoCD also can't pull from git, so it also cannot apply new config.
- "Self-reconcile" sounds like the robot is doing useful work during an outage, but what it's really doing is enforcing the exact same state Kubernetes itself would enforce via its own controllers. Deployments, ReplicaSets, StatefulSets all keep pods healthy with or without ArgoCD.
- The real offline problem is **image pulls** — a new image tag cannot be pulled without internet. That's the same regardless of where ArgoCD runs.

So the "offline resilience" advantage of per-robot ArgoCD is much smaller than it appears. The only genuine asymmetry is AWS region outage, which is manageable.

---

## Why we're picking Online

1. **Operational spread at fleet scale.** Running N ArgoCDs is N times the work to upgrade, monitor, and troubleshoot. At 5+ robots this becomes the dominant operational cost.
2. **Visibility.** "Which robots are on the latest operator-ui? Which ones are stale?" is a one-glance answer with central ArgoCD. With per-robot ArgoCD it's a spreadsheet exercise every time.
3. **Real connectivity model matches this choice.** Robots will have WiFi in operator facilities most of the time. Intermittent drops are tolerated equally well by both topologies. We're not air-gapped; we don't pay for an air-gap-ready architecture.
4. **Nothing from the POC is wasted.** Same gitops repo structure, same Kustomize overlays, same Terraform module — just points at AWS instead of each robot. Rollback to per-robot is always possible if the central approach proves wrong.

---

## What Online needs that we don't have yet

- AWS cluster to host the central ArgoCD (EKS or a small EC2-hosted k8s)
- Tailscale ACL entry allowing central-argocd node to reach `tag:robot` on port 6443
- Central ArgoCD's kubeconfig store needs each robot's credentials
- ApplicationSet config replacing the hand-authored per-robot Application CRs (one-time setup)
- Basic fleet observability (Prometheus federation, Grafana) — separate from the ArgoCD choice but worth calling out

---

## Image pulls — a separate axis, mentioned here for completeness

Image distribution is independent of where ArgoCD runs. Whatever we pick here works with either topology.

- **Today**: DockerHub directly. Fine for the POC and small fleet.
- **Likely next**: Amazon ECR if/when DockerHub rate limits or per-robot credential scoping becomes a concern.
- **Only if needed**: In-robot registry (Zot) for truly disconnected robots. Not pursuing now.
