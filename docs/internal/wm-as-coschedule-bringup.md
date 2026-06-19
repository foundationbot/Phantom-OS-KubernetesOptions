# Bringing up world-model + action-solver inference on a robot

Operational runbook for co-deploying the two paired inference services on a
Thor robot node via the fleet stack:

- **`wm-inference`** — world-model z_ref service (the PROVIDER). Reads camera
  frames, publishes z_ref goals to `/wm_zref_req` ↔ `/wm_zref_resp`.
- **`as-inference`** — action-solver service (the CONSUMER). Reads the WM z_ref
  rings, publishes one ActionCommand per tick to `/as_action` (consumed
  downstream by the WBC / Hand Retargeting Bridge / Head Servo Controller).

Both are `core`-stack DaemonSets in the `positronic` namespace, each gated by
its own node label, each co-scheduling with the other over the shared host
`/dev/shm`. Neither drives `/desired`, so neither is in the
positronic/locomotion/sonic mutual-exclusion group.

Manifests: `manifests/base/wm-inference/`, `manifests/base/as-inference/`.

---

## Prerequisites

1. The robot node is in the cluster and its core Argo app tracks a branch that
   contains both manifests (currently `main`).
2. The **camera** (DMA.video producer) is up — both services gate readiness on
   the first valid frame; without it they never go ready and (with
   `maxUnavailable: 1`) the rollout stalls on that node by design.
3. `dockerhub-creds` is seeded (bootstrap phase 5 / `--seed-pull-secrets`) — the
   DockerHub-direct image refs below pull through it.
4. **No leftover hand-rolled DaemonSet** for either service in another namespace
   (e.g. an earlier `foundation`-ns `wm-inference`). Two pods sharing the same
   z_ref rings will collide — delete the old one first:
   `sudo k0s kubectl delete ds -n <ns> wm-inference` (and/or `as-inference`).

---

## Step 1 — host-config `images:` (resolve the PLACEHOLDER tags)

Both base manifests pin `localhost:5443/<name>:PLACEHOLDER`. Point them at real
arm64/Thor images. Two equivalent ways (the box already uses DockerHub-direct
for most services, so that's the simplest):

```yaml
# /etc/phantomos/host-config.yaml
images:
  # --- world model (z_ref provider) ---
  wm-inference:
    image: foundationbot/wm-inference:v1.0.0-beta.4          # arm64/Thor
  wm-inference-models:
    image: foundationbot/wm-inference-models:v1.0.0-beta.4
  # --- action solver (z_ref consumer) ---
  as-inference:
    image: foundationbot/as-inference:v1.0.0-beta.3          # arm64/Thor
  as-inference-models:
    image: foundationbot/as-inference-models:v1.0.0-beta.3
```

(Offline-robust alternative: `docker push` the arm64 images into the node's
`localhost:5443` registry and use `localhost:5443/<name>:<tag>` refs instead —
a local-registry retag rather than a DockerHub repo-swap. Both are accepted by
the per-host image-override path.)

The images **must be arm64/Thor builds** — the `*-models` images carry
TensorRT engines that are arch- and TRT-version-specific; x86 engines fail CUDA
init.

## Step 2 — host-config `nodeLabels` (schedule both pods)

```yaml
# /etc/phantomos/host-config.yaml
nodeLabels:
  foundation.bot/has-wm-inference: 'true'
  foundation.bot/has-as-inference: 'true'
```

Both default to `false`. They are NOT in the
positronic/locomotion/sonic exclusion group, so enabling them does not require
touching `has-positronic`.

## Step 3 — apply

```bash
sudo bash scripts/bootstrap-robot.sh --image-overrides
```

This injects the `images:` list into the core Argo Application's
`spec.source.kustomize.images` and re-labels the node. Argo reconciles within
~3 min and brings up both pods in `positronic`.

## Step 4 — verify

```bash
sudo k0s kubectl get pods -n positronic -o wide | grep -E 'wm-inference|as-inference'
# both should reach READY 1/1
sudo k0s kubectl logs -n positronic <wm-inference-pod> | grep wm_metrics | tail
```

The loop is live when: `wm-inference` is Ready (serving z_ref), `as-inference`
is Ready (its readiness gates on the first non-stale tick — i.e. it has
attached to WM's rings and gotten an OK z_ref back).

---

## Cross-service contract (get this wrong → silent `NO_ADAPTER`)

The task ids and base sha must agree across BOTH services and the world model's
registry, or every z_ref request fast-rejects:

| field | wm-inference (`wm-inference-config`) | as-inference (`as-inference-config`) | must |
|---|---|---|---|
| task ids | `WM_TASK_IDS` | `AS_TASK_IDS` | **byte-match**, same set |
| base sha | `WM_BASE_SHA` | `AS_BASE_SHA` | each matches its own registry row's `base_ckpt_sha` |

- `AS_TASK_IDS` strings are sent VERBATIM to WM and must equal a WM-registered
  adapter id. A mismatch (wrong string, empty, wrong case) → WM returns
  `NO_ADAPTER` and nothing flows.
- The base manifests ship the Honda defaults
  (`honda_reach_insert,honda_rehome`); override per-host only if the robot runs
  a different task set, and keep WM and AS in lockstep.
- **`AS_BASE_SHA` default is a TEST placeholder** (`foundation_v1_test_base_sha_0000000000`).
  Set the real folded-base sha before a real run.

## Known limitation — the robot will NOT move yet

`as-inference` deliberately does **not** set `AS_ALLOW_STUB_ROBOT_STATE`. Until
the action-solver's Phase-5 DMA varmap proprio reader is wired, the binary's
safety guard downgrades every actionable tick to `NOT_READY` with zeroed
taskspace: the pod runs, the loop flows, but **no actionable command leaves the
service**. This is intentional. Do not add that env to "make it move" — that
gate is an action-solver code deliverable, not a deploy setting.

## Ordering / failure modes

- Bring the camera up before (or alongside) these — readiness depends on it.
- `wm-inference` should be Ready before `as-inference` can go Ready (AS readiness
  needs an OK z_ref). If AS sits not-ready, check WM first.
- A WM pod restart recreates `/wm_zref_resp`; AS re-attaches automatically
  (its z_ref client re-opens on inode replacement). No manual step needed.
- Liveness: WM uses a serve-loop heartbeat (metrics-file mtime); AS uses
  `kill -0 1` (no heartbeat in the AS binary yet) — a wedged-but-alive AS
  process is not auto-restarted, only a crash is.
