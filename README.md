# PhantomOS on k0s

Kubernetes manifests + bootstrap scripts that bring a fresh machine to a
working single-node [k0s](https://k0sproject.io) cluster running the
PhantomOS workloads (operator UI, episode storage, video pipeline,
positronic-control, etc.). Per-host configuration lives on the device
under `/etc/phantomos/`; the repo itself carries no per-robot data.

## Quick start

On the robot:

```bash
git clone https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git \
  /opt/Phantom-OS-KubernetesOptions
cd /opt/Phantom-OS-KubernetesOptions

sudo bash scripts/configure-host.sh    # interactive wizard, writes /etc/phantomos/host-config.yaml
sudo bash scripts/bootstrap-robot.sh   # cluster bringup + ArgoCD + apply config
```

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — the design doc.
  Three-layer model (repo / host / cluster), `host-config.yaml` schema,
  bootstrap phases, per-stack Application model, render flow, per-host
  injection mechanics, migration history, how to extend.
- [`docs/operations.md`](docs/operations.md) — the operator runbook.
  First bringup, day-2 ops, per-phase invocations, migration scenarios,
  troubleshooting by symptom.
- [`docs/rfcs/0001-fleet-control-plane.md`](docs/rfcs/0001-fleet-control-plane.md) —
  long-term direction: control-plane API queried by hardware serial.
- [`docs/positronic-design.md`](docs/positronic-design.md) — positronic-control
  pod-level design (GPU runtime, hostNetwork, image flow).

## Topology in one diagram

```
+---------------------------+      +---------------------------+
|  REPO (this git repo)     |      |  /etc/phantomos/ on robot |
|  - manifests/base/        |      |  - host-config.yaml       |
|  - manifests/stacks/      |      |  - robot                  |
|  - scripts/               |      |  - phantomos-app-*.yaml   |
|  - host-config-templates/ |      |  - operator-ui-pairing.yaml|
+-------------+-------------+      +-------------+-------------+
              |                                  |
              |  read by bootstrap-robot.sh      |
              v                                  v
        +---------------------------------------------+
        |  ArgoCD Applications (cluster)              |
        |    phantomos-<robot>-core                   |
        |    phantomos-<robot>-operator (toggleable)  |
        +---------------------------------------------+
                              |
                              v
              workload pods (positronic, dma-video,
              argus, nimbus, registry, ...)
```

Two ArgoCD Applications per robot — one per stack. Per-host overrides
(image tags, hostPath mounts) are injected into each Application's
`spec.source.kustomize.{images,patches}` at bringup. ArgoCD reconciles
the rest.

## Why k0s and not k3s

k3s ships with SQLite/Kine as its default datastore; we hit a Kine
deadlock under load. k0s uses **etcd** by default (same as upstream
Kubernetes), and the k0s binary bundles kubelet, kube-proxy, CNI in one
file.

## Why hostNetwork for dma-video

The camera pipeline produces ~25 fps of raw frames. Running it through
k0s's overlay network (kube-router) would add latency we can't afford.
All dma-video pods set `hostNetwork: true` — they share the host's
network stack directly. No NAT, no iptables hops, no CNI.

## Why StatefulSets for mongodb / redis / postgres

Stateful services need stable identity and stable storage. A StatefulSet
gives each replica a predictable name (`mongodb-0`, not
`mongodb-7f8b4c9d5-xvz2p`) and a PersistentVolumeClaim that survives pod
restarts.

## CPU isolation

The robot has 20 cores. Cores 15-19 are **isolated from the Linux
scheduler** via GRUB (`isolcpus=15-19`) for real-time work:

| Cores | Assignment |
|---|---|
| 0–14 | General use — k0s, pods, IRQs |
| 15 | xHCI IRQ |
| 16 | EtherCAT |
| 17 | Motor controller |
| 19 | StateMachine + ROS2 + Estimator |

All pods declare **Guaranteed QoS** (requests == limits, whole-number
CPU) so k0s CPU Manager pins them to specific cores on 0-14 and never
onto 15-19. The motor controller runs as a **host systemd service**,
never in k0s.

## Repo layout

```
manifests/
├── base/<workload>/      universal Deployment / DaemonSet / StatefulSet definitions
└── stacks/
    ├── core/             registry, dma-video, positronic, phantomos-api-server, yovariable-server
    └── operator/         argus, nimbus

host-config-templates/
└── _template/            schema for /etc/phantomos/host-config.yaml + Application CR template

scripts/
├── bootstrap-robot.sh    orchestrator
├── configure-host.sh     interactive wizard
├── lib/                  helpers (host-config.py, robot-id.sh)
└── ...

terraform/                installs ArgoCD Helm chart only
docs/                     this directory
```

For everything else — bringing up a robot, day-2 ops, troubleshooting —
see [`docs/operations.md`](docs/operations.md). For the design — see
[`docs/architecture.md`](docs/architecture.md).
