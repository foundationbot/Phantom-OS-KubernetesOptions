# PhantomOS on k0s

Kubernetes manifests that run the three PhantomOS stacks — **dma-video**, **argus**, **nimbus** — on [k0s](https://k0sproject.io), a lightweight single-binary Kubernetes distribution.

This repo is the source of truth for ArgoCD: if it's in `manifests/`, it should be running on the robot.

---

## What you're looking at

```
manifests/
├── dma-video/     camera capture + RTSP streaming (host-networked, latency-critical)
├── argus/         operator UI, auth, users, companies, gateway, nginx, mongodb, redis
└── nimbus/        episode server + S3 upload jobs + postgres
```

Each folder is one Kubernetes namespace. Each YAML file is one service (plus its Service object, ConfigMaps, and any PersistentVolumes it needs).

### How the three stacks talk to each other

```
┌────────────────────────────────────────────────────────┐
│  host: /root/recordings   ←── shared hostPath volume   │
└────────────────────────────────────────────────────────┘
       ▲ writes                            ▲ reads
       │                                   │
┌──────┴───────┐                    ┌──────┴───────┐
│  dma-video   │                    │    nimbus    │
│  (producer,  │                    │  (eg-server, │
│   viewer,    │                    │   eg-jobs,   │
│   mediamtx,  │                    │   postgres)  │
│   rtsp-..)   │                    └──────┬───────┘
└──────────────┘                           │ HTTP :8080
                                           │
                                    ┌──────┴───────┐
                                    │    argus     │
                                    │  (operator-  │
                                    │   ui, auth,  │
                                    │   gateway…)  │
                                    └──────┬───────┘
                                           │ NodePort :30080
                                           ▼
                              http://<robot-ip>:30080
```

- **dma-video → host**: producer writes video to `/root/recordings` via a hostPath volume
- **nimbus → host**: eg-server reads `/root/recordings` (read-only), eg-jobs uploads it to S3
- **argus → nimbus**: argus calls `http://eg-server.nimbus.svc.cluster.local:8080` — Kubernetes DNS resolves this to the eg-server pod
- **user → argus**: NodePort 30080 → nginx → operator-ui + argus-gateway

### Why k0s and not k3s

k3s ships with SQLite/Kine as its default datastore, and we reproduced a failure in our environment where Kine deadlocked under load. k0s uses **etcd** by default (same as upstream Kubernetes), and the k0s binary bundles everything — kubelet, kube-proxy, CNI, everything — in one file. No surprises.

### Why hostNetwork for dma-video

The camera pipeline produces ~25 fps of raw frames. Running it through k0s's overlay network (kube-router) would add latency we can't afford. All dma-video pods set `hostNetwork: true` — they share the host's network stack directly. No NAT, no iptables hops, no CNI.

### Why StatefulSets for mongodb/redis/postgres

Stateful services need stable identity and stable storage. A StatefulSet gives each replica a predictable name (`mongodb-0`, not `mongodb-7f8b4c9d5-xvz2p`) and a PersistentVolumeClaim that survives pod restarts. The alternative — Deployments with bolted-on PVCs — doesn't correctly handle scaling or recovery for databases.

### CPU isolation

The robot has 20 cores. Cores 15-19 are **isolated from the Linux scheduler** via GRUB (`isolcpus=15-19`) for real-time work:

| Cores | Assignment |
|---|---|
| 0–14 | General use — k0s, pods, IRQs |
| 15 | xHCI IRQ |
| 16 | EtherCAT |
| 17 | Motor controller |
| 19 | StateMachine + ROS2 + Estimator |

All pods declare **Guaranteed QoS** (requests == limits, whole-number CPU) so k0s CPU Manager pins them to specific cores on 0-14 and never onto 15-19. The motor controller runs as a **host systemd service**, never in k0s.

---

## Running this locally

If you want to try this on your own machine (not the robot), here's how. The goal is to get all three namespaces running on a single Linux box.

### What you need

- Ubuntu LTS (22.04 or 24.04), x86-64
- Root access (`sudo`)
- Internet access to pull Docker images from DockerHub
- A DockerHub account with pull access to the `foundationbot/*` private images

### Step 1: Uninstall k3s if it's installed

```bash
# Only run this if k3s is actually installed. Check first:
which k3s
# If the above prints a path, run:
sudo /usr/local/bin/k3s-uninstall.sh
```
The uninstaller removes the binary, the systemd service, and `/var/lib/rancher/k3s/`.

### Step 2: Install k0s

```bash
# Download the k0s binary to /usr/local/bin/k0s
curl -sSLf https://get.k0s.sh | sudo sh

# Verify it installed
k0s version
```
`curl -sSLf | sh` pipes the install script straight into a shell — the `-f` flag makes curl fail on HTTP errors instead of silently piping an error page into sh.

### Step 3: Write the k0s config

```bash
# Create the config directory and write the config file
sudo mkdir -p /etc/k0s
sudo tee /etc/k0s/k0s.yaml <<'EOF'
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  storage:
    type: etcd
  workerProfiles:
    - name: default
      values:
        cpuManagerPolicy: static
        systemReserved:
          cpu: "1000m"
          memory: "1Gi"
        kubeReserved:
          cpu: "500m"
          memory: "512Mi"
EOF
```
`tee` with a heredoc writes the YAML to the file. The `<<'EOF'` form (quotes around EOF) disables shell variable expansion inside the heredoc, so `$host` etc. are treated literally.

`cpuManagerPolicy: static` is what enables core pinning for Guaranteed QoS pods. Without it, the scheduler treats CPU requests as "a fraction of available CPU time" rather than "this many physical cores."

### Step 4: Install k0s as a systemd controller+worker

```bash
# "controller+worker" means one node running both the control plane and workloads
# (For the robot this is correct — single-node setup.)
sudo k0s install controller --single --config /etc/k0s/k0s.yaml

# Start the service
sudo k0s start

# Wait ~30 seconds, then check status
sudo k0s status
```
`--single` tells k0s "this is a single-node cluster, don't expect other nodes to join."

### Step 5: Configure kubectl

```bash
# Generate a kubeconfig and export KUBECONFIG for this shell
sudo k0s kubeconfig admin > ~/.kube/config
chmod 600 ~/.kube/config

# Verify you can talk to the cluster
kubectl get nodes
```
Your node should show status `Ready`. If it's `NotReady` for more than a minute, check `sudo k0s status` and `journalctl -u k0scontroller`.

### Step 6: Create DockerHub credentials (pull secret)

The `foundationbot/*` images are private, so every namespace needs a pull secret. Replace `YOUR_USERNAME` and `YOUR_TOKEN` with your DockerHub username and a [personal access token](https://hub.docker.com/settings/security).

```bash
for ns in argus nimbus; do
  kubectl create secret docker-registry dockerhub-creds \
    --namespace "$ns" \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=YOUR_USERNAME \
    --docker-password=YOUR_TOKEN
done
```
Note: the namespaces don't exist yet. This will fail. So first apply the namespaces (Step 7), then come back and run this loop.

`docker-registry` is a special Secret type k8s knows how to format for the kubelet's image pull machinery. Each namespace keeps its own copy because Secrets are namespace-scoped.

### Step 7: Create namespaces + shared volumes

```bash
# Apply the three namespaces first — most other manifests reference them
kubectl apply -f manifests/dma-video/namespace.yaml
kubectl apply -f manifests/argus/namespace.yaml
kubectl apply -f manifests/nimbus/namespace.yaml

# The shared /root/recordings volume (PV + PVC)
sudo mkdir -p /root/recordings
kubectl apply -f manifests/nimbus/recordings-volume.yaml
```

Now go back and run the pull secret loop from Step 6.

### Step 8: Apply stateful services first

Databases need to be running before app services try to connect to them.

```bash
kubectl apply -f manifests/argus/mongodb.yaml
kubectl apply -f manifests/argus/redis.yaml
kubectl apply -f manifests/nimbus/postgres.yaml

# Watch them come up — ^C to exit
kubectl get pods -A -w
```
`-A` watches all namespaces. `-w` streams updates as they happen. Wait until mongodb, redis, and postgres all show `Running` with `1/1` ready.

### Step 9: Apply everything else

```bash
kubectl apply -f manifests/dma-video/
kubectl apply -f manifests/argus/
kubectl apply -f manifests/nimbus/
```
`kubectl apply -f <directory>/` applies every YAML file in the directory. It's safe to re-run — Kubernetes treats `apply` as declarative, so it diffs what's there against what you're applying and only changes what's different.

### Step 10: Access the Operator UI

```bash
# Find the node IP
kubectl get nodes -o wide
```

Open `http://<node-ip>:30080` in a browser. Login with one of the seeded users, e.g. `gaurav / gaurav123123`.

---

## Common kubectl commands

| Command | What it does |
|---|---|
| `kubectl get pods -A` | List every pod across every namespace |
| `kubectl get pods -n argus` | List pods in the argus namespace |
| `kubectl describe pod <name> -n <ns>` | Show detailed pod info including recent events — use this when a pod is stuck |
| `kubectl logs <pod> -n <ns>` | Print container logs |
| `kubectl logs -f <pod> -n <ns>` | Follow logs (like `tail -f`) |
| `kubectl exec -it <pod> -n <ns> -- /bin/sh` | Shell into a running pod |
| `kubectl delete pod <pod> -n <ns>` | Delete a pod — the Deployment/StatefulSet will recreate it |
| `kubectl get events -n <ns> --sort-by=.lastTimestamp` | See recent events (pulls, schedules, errors) |

---

## Tearing it all down

```bash
# Remove everything from the cluster, but keep the cluster itself
kubectl delete -f manifests/dma-video/
kubectl delete -f manifests/argus/
kubectl delete -f manifests/nimbus/

# PersistentVolumes have reclaimPolicy: Retain, so data stays on disk at
# /var/lib/k0s-data/* even after deletion. Remove manually if wanted.
```

To uninstall k0s entirely:
```bash
sudo k0s stop
sudo k0s reset              # removes all cluster state
sudo rm /usr/local/bin/k0s
```

---

## Local image registry (priority-first mirror)

Each robot runs a `registry:2` pod (see [manifests/base/registry/](manifests/base/registry/)) named `k0s-registry` that hosts locally-compiled images like `positronic-control` and serves as a manually-primed cache for DockerHub-sourced images. containerd is configured to try `http://localhost:5443` first and fall back to `registry-1.docker.io` — so primed images survive a DockerHub outage and locally-pushed tags transparently shadow upstream. (Auto-pull-through caching is intentionally *not* enabled because Distribution `registry:2` is read-only in proxy mode, which would block locally-built image pushes; the prime script fills the gap.)

The repo ships three scripts:

| Script | Purpose | Runs as |
|---|---|---|
| [scripts/configure-k0s-containerd-mirror.sh](scripts/configure-k0s-containerd-mirror.sh) | One-time per-robot: writes `/etc/docker/daemon.json` + `/etc/k0s/containerd.d/hosts/docker.io/hosts.toml` + containerd import TOML, restarts docker & k0s | root |
| [scripts/prime-registry-cache.sh](scripts/prime-registry-cache.sh) | Pre-populates the registry with images (by direct push, not proxy) so they work offline. Supports explicit list, `--from-file`, `--from-cluster`, `--from-manifests <dir>` | requires `docker login` for private images |
| [scripts/validate-local-registry.sh](scripts/validate-local-registry.sh) | 13 checks across docker / k8s / containerd layers. Exit code = failure count | any user (tests needing `sudo k0s ctr` skip if passwordless sudo is unavailable) |

### Bootstrap on a new robot

```bash
git pull
sudo bash scripts/configure-k0s-containerd-mirror.sh
# wait for ArgoCD to sync manifests/base/registry (~30s)
docker login                  # so the prime script can pull private foundationbot/* images
sudo bash scripts/prime-registry-cache.sh --from-manifests manifests/
sudo bash scripts/validate-local-registry.sh
```

### Building and deploying `positronic-control`

```bash
cd ~/development/foundation/imu-policy/positronic_control
TAG=$(git rev-parse --short HEAD)
docker build -f docker/<chosen>.Dockerfile -t localhost:5443/positronic-control:$TAG .
docker push localhost:5443/positronic-control:$TAG
# then bump newTag in manifests/robots/<robot>/kustomization.yaml and push —
# ArgoCD rolls the pod automatically
```

---

## positronic-control deployment

The positronic-control stack runs as a single Kubernetes Deployment in
the `positronic` namespace. It pulls two images from the local registry
(`positronic-control` for the executing container, `phantom-models` for
the bundled weights), uses an initContainer + emptyDir to deliver the
models, and gets GPU access via `runtimeClassName: nvidia`. Default
mode is `sleep infinity` so operators can `kubectl exec` in for
interactive ROS work; flip the `PHANTOM_CMD` key in the
`positronic-config` ConfigMap to run as a service.

- **How do I do X?** — [docs/positronic-cheatsheet.md](docs/positronic-cheatsheet.md):
  build/push images, bump tags, deploy, sanity-check, toggle
  `PHANTOM_CMD`, diagnose failures, registry ops.
- **Why does it look this way?** — [docs/positronic-design.md](docs/positronic-design.md):
  the two repos, three images, storage layers, pod composition,
  per-robot overlays, ArgoCD wiring, known limitations.

ArgoCD picks this up automatically once `feat/local-registry-mirror`
merges to `main` (the per-robot Application at
[`gitops/apps/phantomos-mk09.yaml`](gitops/apps/phantomos-mk09.yaml) is
pinned to `targetRevision: main`).

---

## Troubleshooting

**Pods stuck in `ImagePullBackOff`**
Usually means the `dockerhub-creds` secret is missing or wrong. Check: `kubectl get secret dockerhub-creds -n <ns>` — if it's not there, create it (Step 6).

**Pods stuck in `Pending` with "0/1 nodes are available: ... Insufficient cpu"**
Every pod in this repo uses Guaranteed QoS with whole-number CPUs. If you're running on a machine with fewer than ~14 allocatable cores, some pods won't schedule. Edit the `resources.requests.cpu` and `resources.limits.cpu` values down to a fractional CPU (e.g. `"500m"`) on the non-critical services (camera-params, nginx, argus-auth/user/company).

**`CrashLoopBackOff` on a database pod**
Check logs: `kubectl logs <pod> -n <ns>`. Most common cause: the hostPath directory exists but has wrong permissions. Try `sudo chown -R 999:999 /var/lib/k0s-data/mongodb` (UID 999 is the mongo user inside the image).

**`eg-jobs` crashes on startup**
By default, the iot-certs volume mount is commented out in [manifests/nimbus/eg-jobs.yaml](manifests/nimbus/eg-jobs.yaml). Create the secret and uncomment the volume when deploying to production:
```bash
kubectl create secret generic iot-certs --namespace nimbus --from-file=/root/episode-agent/
```
