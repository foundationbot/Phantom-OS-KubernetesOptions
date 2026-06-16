# phantom-psi stack — Ψ₀ VLA → locomotion

`phantom-psi` is the GitOps-managed form of the Ψ₀ VLA workload on a robot,
modelled directly on the existing **`phantom-sonic`** stack: one node-label-gated
DaemonSet, per-host knobs rendered into a ConfigMap by bootstrap, and a
`positronic.sh` subcommand for day-to-day ops. It supersedes the hand-applied
`psi0-loco` Deployment from the ch4 bring-up (see the Psi0-VLA repo's
`k0sdeployment.md`).

## What it runs

A single pod (`positronic`-style colocation) in the **`psi`** namespace, three
containers sharing the host `/dev/shm` DMA rings (hostNetwork + hostIPC):

| Container | Image | Role |
|---|---|---|
| `psi0-vla` | `psi0-policy` | Ψ₀ flow policy on the GPU (`psi.deploy.psi0_dma_runner`): reads the egocentric camera ring + proprio state ring, writes the `(Ta,Da)` action ring. GPU via the NVIDIA device plugin (`nvidia.com/gpu: 1`). |
| `bridge` | `phantom-loco` | `bridge.psi0_loco_bridge`: reads the action ring and drives the locomotion command stream (gait/height/yaw passthrough gated by `PSI0_ENABLE_*`, default off — spec-004 AC-7). |
| `walking` | `phantom-loco` | `inference.policy_node`: the lower-body walking ONNX policy. |

> Images are currently **local** (`psi0-policy:thor-cu130`, `phantom-loco:local`,
> built on-device and imported into k0s containerd). They're registered in
> `CONTAINER_TARGETS` for per-robot tag override; publish them to the fleet
> registry before relying on this on non-ch4 robots. `psi0-policy` MUST be a
> CUDA-13 / sm_110 torch base on Thor (the Orin igpu base does not run there).

## On / off (node label)

Gated on `foundation.bot/has-psi` (default **`false`**), so adding the stack to
the core kustomization schedules **zero** pods until a robot opts in. `has-psi`
drives the body via the bridge, so it is **mutually exclusive** with
`has-sonic`, `has-locomotion`, and default-on `has-positronic` — the host-config
validator rejects more than one.

Enable on a robot (`/etc/phantomos/host-config.yaml`):

```yaml
nodeLabels:
  foundation.bot/has-psi: 'true'
  foundation.bot/has-positronic: 'false'   # required — psi drives the body
  foundation.bot/has-sonic: 'false'
  foundation.bot/has-locomotion: 'false'
```

then `sudo bash scripts/bootstrap-robot.sh` (reconciles node labels + renders
the ConfigMap). Quick label-only flip:

```bash
sudo k0s kubectl label node <robot> \
  foundation.bot/has-psi=true foundation.bot/has-positronic=false --overwrite
```

> Migrating off the hand-applied `psi0-loco` Deployment: delete it first so two
> workloads don't contend for the single GPU —
> `sudo k0s kubectl -n psi delete deploy psi0-loco`.

## Configuration (host-config → ConfigMap)

Per-host knobs live in the `phantomPsi:` block of `host-config.yaml`. Bootstrap
phase **8b `psi-config`** renders them into the `phantom-psi-config` ConfigMap
(all three containers `envFrom` it); `psi0-vla`'s command carries
`${VAR:-default}` shell-defaults so the pod still starts before the CM exists.
Every field is optional and falls back to the documented default.

| host-config field | env var | default |
|---|---|---|
| `runDir` | `PSI0_RUN_DIR` | `full_task.real…2606120333` |
| `ckptStep` | `PSI0_CKPT_STEP` | `120000` |
| `cameraId` | `PSI0_CAMERA_ID` | `0` (bottom) |
| `stateQueue` | `PSI0_STATE_QUEUE` | `psi0_state_j24` |
| `actionQueue` | `PSI0_ACTION_QUEUE` | `psi0_actions_j24` |
| `instruction` | `PSI0_INSTRUCTION` | `Grasp and lift part.` |
| `rosDomainId` | `ROS_DOMAIN_ID` | `43` |
| `bridgeRateHz` | `PSI0_BRIDGE_RATE_HZ` | `50` |
| `enableGait` / `enableHeight` / `enableYaw` | `PSI0_ENABLE_*` | `0` (AC-7 gated) |
| `walkingOnnx` | `POLICY_ONNX_PATH` | `/models/walking/policy.onnx` |

Change a value → `sudo bash scripts/bootstrap-robot.sh --psi-config` (re-renders
the CM and rolls the DaemonSet).

## Operating (`positronic.sh psi`)

```bash
bash scripts/positronic.sh psi status                 # DS + pod + per-container state
bash scripts/positronic.sh psi logs psi0-vla -f       # tail one container
bash scripts/positronic.sh psi logs                   # all three, prefixed
bash scripts/positronic.sh psi exec psi0-vla          # shell into a container
bash scripts/positronic.sh psi restart                # rollout restart the DS
```

## Files

| File | Change |
|---|---|
| `manifests/base/phantom-psi/{namespace,phantom-psi,kustomization}.yaml` | new — the DaemonSet + psi ns |
| `manifests/stacks/core/kustomization.yaml` | add `phantom-psi` to the core stack |
| `scripts/lib/host-config.py` | `has-psi` registry entry; `phantomPsi` renderer (`get-phantom-psi-config-kv`); `psi0-policy`/`phantom-loco` image targets; `has-psi` in the body-driver mutual-exclusion validator |
| `host-config-templates/_template/host-config.yaml` | `phantomPsi` options block + `has-psi` node label |
| `scripts/bootstrap-robot.sh` | phase 8b `psi-config` (renders `phantom-psi-config`) |
| `scripts/positronic.sh` | `psi` subcommand (status/logs/exec/restart) |
