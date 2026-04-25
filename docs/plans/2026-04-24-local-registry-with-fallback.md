# Plan: Local container registry with DockerHub fallback

**Date:** 2026-04-24
**Status:** Draft — not yet executed
**Scope:** Add a local registry on each robot that (a) hosts locally-compiled images
(e.g. `positronic_control`) and (b) acts as a priority-ordered pull source: try
local first, fall back to DockerHub.

---

## 1. Current state — how images are pulled today

### 1.1 Registries in use

All cluster workloads reference exactly two registries today, both DockerHub:

| Image | Access | Pull policy | Pull secret |
|---|---|---|---|
| `foundationbot/argus.auth:qa` | private | `Always` | `dockerhub-creds` |
| `foundationbot/argus.user:qa` | private | `Always` | `dockerhub-creds` |
| `foundationbot/argus.company:qa` | private | `Always` | `dockerhub-creds` |
| `foundationbot/argus.gateway:qa` | private | `Always` | `dockerhub-creds` |
| `foundationbot/argus.operator-ui:qa` | private | `Always` | `dockerhub-creds` |
| `foundationbot/nimbus.s3_dynamo_athena:main` | private | `Always` | `dockerhub-creds` |
| `foundationbot/nimbus.s3_dynamo_athena-jobs:main` | private | `Always` | `dockerhub-creds` |
| `foundationbot/dma-video:main` (producer / viewer / rtsp-streamer / camera-params) | private | `Always` | `dockerhub-creds` |
| `mongo:7` / `redis:7-alpine` / `postgres:16` / `nginx:latest` / `bluenviron/mediamtx:latest` | public | default (`IfNotPresent`) | `dockerhub-creds` listed but unused |

Source paths (spot-check):
- `manifests/base/argus/argus-auth.yaml:16-22`
- `manifests/base/dma-video/producer.yaml:20-22`
- `manifests/base/nimbus/eg-server.yaml:16-21`

### 1.2 Authentication

Each namespace needs its own copy of `dockerhub-creds` (Secrets are namespace-scoped).
Bootstrap procedure lives in `README.md:168-198`. Every `imagePullSecrets:` block
references this one name.

### 1.3 Tag pinning in overlays

Robot overlays rewrite tags (not hosts) via Kustomize `images:`:

```yaml
# manifests/robots/mk09/kustomization.yaml
images:
  - name: foundationbot/argus.operator-ui
    newTag: 585e58803318f5366d793986ad3e6129538b8a81
```

This only rewrites `:qa` → `:<sha>`. No registry-host rewrite anywhere.

### 1.4 containerd config

k0s's containerd has no hosts-level customization today. All pulls go straight
to `registry-1.docker.io`. No mirror, no caching layer, no offline fallback.

---

## 2. The goal

Add a local registry per robot such that:

1. **Locally-compiled images** (the new `positronic_control` deployment, future
   dev builds) can be pushed to `localhost:5443/...` and pulled by k0s without a
   round-trip through DockerHub.
2. **Priority ordering for existing `foundationbot/*` images**: containerd tries
   the local registry first; on 404/unreachable, falls back to DockerHub. This
   gives:
   - Offline resilience: robot keeps running if DockerHub is unreachable and the
     image has been pulled at least once.
   - Faster rollouts: cached images pull at LAN speed.
   - Transparent override: pushing a locally-built image to the local registry
     under the same name/tag as DockerHub shadows the upstream copy without
     editing any manifest.

---

## 3. Options considered

### Option A — Pull-through cache mirror (recommended)

Run `registry:2` with `REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io`.
The registry serves two roles simultaneously:

- **Local origin** for `localhost:5443/positronic-control:<sha>` and similar
  locally-built images (direct push).
- **Pull-through cache** for anything under `docker.io/*` — on a cache miss, the
  registry itself fetches from DockerHub, stores, and returns to the client.

containerd hosts.toml then points `docker.io` lookups at `http://localhost:5443`
first, with `registry-1.docker.io` as a secondary host. So:

1. Pod requests `foundationbot/argus.auth:qa`
2. containerd resolves `docker.io/foundationbot/argus.auth:qa` → tries
   `http://localhost:5443` first
3. Cache hit → return. Cache miss → registry fetches from upstream, stores,
   returns.
4. If `localhost:5443` itself is down, containerd falls through to
   `registry-1.docker.io` directly (pod's own `imagePullSecrets` authenticates).

**Pros:**
- Answers both parts of the ask (local-built images AND priority fallback).
- Zero manifest changes required — existing `image: foundationbot/argus.auth:qa`
  references just work.
- Offline after first pull. Good fit for `offline-vs-online-argocd.md` theme.
- Cache lives on disk; survives registry container restart.

**Cons:**
- Registry needs DockerHub credentials itself (to proxy private `foundationbot/*`
  images) — single shared credential, configured via
  `REGISTRY_PROXY_USERNAME` / `REGISTRY_PROXY_PASSWORD`.
- The robot's `dockerhub-creds` Secret becomes partially redundant (still needed
  for the fallback path when the cache is down).
- Cache invalidation: `Always` pull policy + `:qa` floating tag means containerd
  asks for the manifest on every pod start. The cache honours that correctly
  (re-checks upstream), but if upstream is offline, containerd will treat stale
  manifests as current — behavior to verify during testing.

### Option B — containerd hosts.toml multi-host, no proxy

Same `hosts.toml` fallback mechanism, but `localhost:5443` is a plain
(non-proxying) registry. We only push images there that we want to shadow.

**Pros:**
- Simpler registry (no proxy mode).
- No shared DockerHub credential on the registry.

**Cons:**
- No auto-caching. Every `foundationbot/*` image we want locally available has
  to be manually pulled + retagged + pushed. Easy to forget one, painful to
  maintain.
- For images not pushed locally, every pod start still hits DockerHub → no
  offline resilience benefit for existing workloads.

### Option C — Local registry only for locally-built images (current trajectory)

Keep all `foundationbot/*` on DockerHub. Only `positronic_control` and future
dev builds live at `localhost:5443/positronic-control:<sha>`. No priority
ordering, no mirror configuration.

**Pros:**
- Minimal change. Matches what we already discussed.
- No shared credential problem.

**Cons:**
- Doesn't answer the priority-ordering ask.
- No offline resilience for existing workloads.

---

## 4. Recommendation

**Option A (pull-through cache mirror).** It's the only option that cleanly
satisfies both halves of the ask, and the offline-resilience benefit alone
justifies the single shared credential on the registry.

If the shared-credential model is unacceptable for security reasons, fall back
to **Option C for now** and revisit when offline operation becomes a hard
requirement.

---

## 5. Implementation plan (Option A)

### 5.1 Deploy the registry (per robot, one-time)

```bash
sudo mkdir -p /var/lib/registry
docker run -d --restart=always --name registry \
  -p 5443:5443 \
  -v /var/lib/registry:/var/lib/registry \
  -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
  -e REGISTRY_PROXY_USERNAME="$DOCKERHUB_USER" \
  -e REGISTRY_PROXY_PASSWORD="$DOCKERHUB_TOKEN" \
  registry:2
```

Notes:
- `--restart=always` + `/var/lib/registry` hostPath persists cache across reboots.
- Credentials should come from a file not the shell history; in practice, bake
  into a systemd service unit on the robot or use Terraform to template it.

### 5.2 Allow Docker CLI to push plain-HTTP

`/etc/docker/daemon.json`:
```json
{ "insecure-registries": ["localhost:5443"] }
```
Then `sudo systemctl restart docker`. Required for `docker push
localhost:5443/...` to work without TLS.

### 5.3 Configure containerd registry mirrors

Create the hosts-config tree:

```
/etc/k0s/containerd.d/hosts/
└── docker.io/
    └── hosts.toml
```

Contents of `docker.io/hosts.toml`:

```toml
server = "https://registry-1.docker.io"

[host."http://localhost:5443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true

[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
```

Key points:
- `server = ...` is the authoritative host — used when no `[host.<x>]` entry
  applies, and as the upstream identity for credential matching.
- The first `[host.*]` block is tried first. `override_path = true` is
  required when the mirror serves all repositories at its root path (standard
  pull-through cache behavior).
- If `localhost:5443` returns 404 or is unreachable, containerd falls through
  to the next `[host.*]` block.

Then ensure containerd's main config references this directory:

```toml
# /etc/k0s/containerd.toml (or wherever the generated config lives)
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/k0s/containerd.d/hosts"
```

Restart k0s: `sudo k0s stop && sudo k0s start`.

### 5.4 Validate end-to-end

```bash
# Push a test image through the local registry
docker pull hello-world
docker tag hello-world localhost:5443/library/hello-world:test
docker push localhost:5443/library/hello-world:test

# k0s containerd pulls it via the mirror
sudo k0s ctr -n k8s.io images pull --plain-http localhost:5443/library/hello-world:test

# Check that an existing DockerHub image now goes through the mirror
sudo k0s ctr -n k8s.io images pull docker.io/library/alpine:3.19
# Then inspect the registry's storage dir — a manifest for alpine should be there:
sudo find /var/lib/registry -name '*alpine*' | head
```

Expected result: the cache directory contains both `hello-world` (pushed) and
`alpine` (proxied).

### 5.5 Deploy `positronic_control` against the new registry

Per the prior discussion (now wired through the same flow):

```bash
cd ~/development/foundation/imu-policy/positronic_control
docker build -f docker/<chosen>.Dockerfile -t localhost:5443/positronic-control:$(git rev-parse --short HEAD) .
docker push localhost:5443/positronic-control:$(git rev-parse --short HEAD)
```

Manifest in `manifests/base/positronic/positronic-control.yaml`:
```yaml
image: localhost:5443/positronic-control:PLACEHOLDER
imagePullPolicy: IfNotPresent
# no imagePullSecrets — local registry is unauthenticated
```

Robot overlay `manifests/robots/mk09/kustomization.yaml`:
```yaml
images:
  - name: localhost:5443/positronic-control
    newTag: <git-sha-of-pushed-image>
```

### 5.6 (Optional, later) Rewrite existing images through the mirror transparently

With Option A in place, no rewrite is needed — containerd already routes
`foundationbot/*` through the local registry first. The `imagePullSecrets`
remain correct for the fallback path.

If we later want to drop `dockerhub-creds` from most pods, we'd switch
`imagePullPolicy` to `IfNotPresent` on the `foundationbot/*` workloads and rely
on the mirror-side credential. Deferred until the fallback path stops being
exercised in practice.

---

## 6. Risks and open questions

1. **Shared DockerHub credential on the registry.**
   The mirror holds one credential that authenticates proxying of private images.
   Anyone who can reach the robot on port 5443 effectively gets read access to
   every private `foundationbot/*` image. The registry should bind to
   `127.0.0.1:5443`, not `0.0.0.0:5443`, unless there's a reason other hosts
   need to pull from it.

2. **`imagePullPolicy: Always` + cache staleness.**
   Current manifests set `Always`, which sends a manifest HEAD on every pod
   start. Pull-through registries honour this (they re-validate upstream), but
   when upstream is unreachable the behavior is registry-implementation
   specific. Needs explicit test: stop the robot's network, restart a pod, see
   whether kubelet accepts the cached manifest or errors out. If the latter,
   we may need to flip `Always` → `IfNotPresent` on the `foundationbot/*`
   workloads to preserve offline operation.

3. **k0s upgrade path.**
   k0s sometimes regenerates `/etc/k0s/containerd.toml` on upgrade. Our
   `config_path` addition may get clobbered. Need to verify whether k0s has an
   "include" directory for persistent custom config (the `containerd.d/` path
   used above is the documented k0s mechanism, but I want to confirm by test
   on the robot rather than take it on faith).

4. **Floating tags (`:qa`, `:main`).**
   Pull-through caches key on the exact tag. Since `:qa` and `:main` are mutable
   in CI, the cache may hold a stale manifest digest while CI has pushed a new
   one. With `imagePullPolicy: Always`, the HEAD check should catch this — but
   only if upstream is reachable. Offline, we'll run whatever was last cached.
   Acceptable for this fleet.

5. **Private IP for the registry.**
   If multiple robots ever share a registry (e.g. a site-level mirror), the
   `localhost:5443` name has to become a real hostname. The containerd hosts
   config would need to match. Out of scope for this plan; flagging.

6. **Argo CD reconciliation**
   Argo doesn't pull images directly, only reads manifests. So Argo is
   orthogonal — no change needed to `gitops/*`. But image *tags* in
   `manifests/robots/*/kustomization.yaml` still need to be bumped in git for
   the rollout to happen — same pattern as today.

---

## 7. Validation checklist

- [ ] Registry container up, listens on `127.0.0.1:5443`, storage path
      persisted.
- [ ] `docker push localhost:5443/test:1` succeeds.
- [ ] `sudo k0s ctr -n k8s.io images pull --plain-http localhost:5443/test:1`
      succeeds.
- [ ] `sudo k0s ctr -n k8s.io images pull docker.io/library/alpine:3.19` —
      registry storage directory grows.
- [ ] A pod referencing `foundationbot/argus.auth:qa` starts with the registry
      as primary source (check containerd logs: `journalctl -u k0scontroller |
      grep registry`).
- [ ] With outbound internet blocked (simulate with `sudo iptables -A OUTPUT
      -d registry-1.docker.io -j REJECT` or equivalent), an existing pod
      restart still succeeds.
- [ ] `positronic_control` pod pulls its locally-built image without
      `imagePullSecrets`.

---

## 7a. Priming the cache manually

The registry's pull-through cache only fills when containerd actually
requests an image. Two problems follow:

1. **Cold cache + DockerHub outage** — if a pod is scheduled for the first
   time while DockerHub is unreachable, containerd can't reach upstream
   and the mirror has nothing to serve. The pod fails to start.
2. **First-pull latency** — first pod start after a fresh robot bringup
   pays the full DockerHub pull cost for every image.

`scripts/prime-registry-cache.sh` solves both by doing a direct
`docker pull → tag → push` of each image into the local registry *under
its docker.io-equivalent path*. The images then sit in the registry's
regular storage (not just the proxy cache) and are served regardless of
upstream connectivity.

The path mapping is the key detail. A reference like `mongo:7` lives
upstream at `docker.io/library/mongo:7`; containerd's hosts.toml rewrite
requests `GET /v2/library/mongo/manifests/7` on our mirror. The prime
script pushes to `localhost:5443/library/mongo:7` so the storage path
matches exactly. Refs with an explicit namespace (`foundationbot/...`)
and fully-qualified refs (`docker.io/...`, `registry-1.docker.io/...`)
are normalized the same way.

### Usage

```bash
# Prime a handful of images explicitly
sudo bash scripts/prime-registry-cache.sh \
  foundationbot/argus.auth:qa \
  foundationbot/dma-video:main \
  mongo:7

# Prime every image the running cluster uses right now
sudo bash scripts/prime-registry-cache.sh --from-cluster

# Prime every image this repo references (reads manifests/*.yaml)
sudo bash scripts/prime-registry-cache.sh --from-manifests manifests/

# Prime from a curated list
sudo bash scripts/prime-registry-cache.sh --from-file scripts/priming-seed.txt
```

Prerequisites:
- `docker login` (for private `foundationbot/*` images — same credential
  used in `dockerhub-creds` works).
- `REGISTRY_HOST=localhost:5443` reachable (the registry pod is up).

The script is idempotent: re-priming an image that's already present is
a near-no-op because docker push skips already-uploaded layers. Exit
code = number of images that failed to prime.

### When to re-prime

- After CI publishes a new tag of something you care about (e.g.,
  `foundationbot/argus.auth:qa` got bumped). Direct push overwrites the
  stale proxy-cached entry.
- Before taking the robot into a known-offline environment (factory,
  field trial, flight).
- After bootstrap on a new robot, once `configure-k0s-containerd-mirror.sh`
  has been run.

### Recommended post-bootstrap routine

```bash
# On the robot, as a one-time setup:
git pull
sudo bash scripts/configure-k0s-containerd-mirror.sh
# wait for ArgoCD to deploy the registry pod (~30s)
sudo bash scripts/prime-registry-cache.sh --from-manifests manifests/
sudo bash scripts/validate-local-registry.sh
```

---

## 8. Out of scope for this plan

- Fleet-level (cross-robot) registry.
- TLS / auth on the local registry itself.
- Automating image GC on the registry (`registry garbage-collect`).
- Migrating `foundationbot/*` images to a self-hosted origin (the mirror
  keeps DockerHub as source of truth; Terraform/CI session will eventually
  revisit this).
- Moving the `positronic_control` build into CI — out of scope, this plan
  assumes robot-local `docker build`.

---

## 9. Implementation notes (2026-04-24)

The plan's Section 5.1 originally proposed running the registry as a
host-side `docker run` container. On review we split the work into three
layers so the cluster-level part stays GitOps-managed like everything
else in this repo:

| Layer | Landed as |
|---|---|
| Registry pod + storage | `manifests/base/registry/{namespace,registry,kustomization}.yaml` — Deployment with `hostNetwork: true`, hostPath PV at `/var/lib/registry`, `REGISTRY_PROXY_REMOTEURL` env, optional `dockerhub-proxy-creds` Secret |
| containerd mirror config + docker daemon.json | `scripts/configure-k0s-containerd-mirror.sh` — one-time per-robot, idempotent, writes `hosts.toml` + containerd import TOML + daemon.json, restarts services |
| Validation | `scripts/validate-local-registry.sh` — 13 checks across docker / k8s / containerd layers; exit code = failure count |
| First consumer | `manifests/base/positronic/{namespace,positronic-control,kustomization}.yaml`, wired into `manifests/robots/mk09/kustomization.yaml` |

Terraform was deliberately **not** extended. The existing module's
scope (per `terraform/README.md:42-48`) is "kubeconfig-only bootstrap";
host-level containerd/docker config sits outside that boundary and
matches the same "install manually per node" model as k0s itself.

### What still needs to happen on the robot

1. `git pull` this repo onto the robot.
2. `sudo bash scripts/configure-k0s-containerd-mirror.sh` — writes host
   config, restarts docker + k0s. Takes ~30s.
3. `kubectl create secret generic dockerhub-proxy-creds -n registry
   --from-literal=username=... --from-literal=password=...` — optional;
   without it, proxying private `foundationbot/*` images will 401 and
   containerd falls through to DockerHub directly.
4. ArgoCD reconciles `manifests/base/registry/` automatically (it's
   included via `manifests/robots/mk09/kustomization.yaml`).
5. `sudo bash scripts/validate-local-registry.sh` — must print `0 failed`.
6. Build + push `positronic-control`, bump `newTag` in the mk09 overlay.
