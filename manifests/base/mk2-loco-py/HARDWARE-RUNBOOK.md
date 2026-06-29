# mk2-loco-py — hardware bring-up runbook

MK2 velocity-twist locomotion policy as a 50 Hz Python node + web console.
The workload ships **safe** (`OBSERVE_ONLY=1`, empty `WEB_TOKEN`): it runs the full
sensor → obs → ONNX → status loop and serves the console, but writes **nothing**
to `/desired`. Arming to actually command the robot is a **deliberate, supervised**
step (below) — never the default.

Image: `foundationbot/dma-ghost-wbc-inference:v0.1.0-beta.10-loco-aarch64` (immutable release tag), arm64/Thor. Pin by **tag** in host-config — the renderer expects `repo:tag`, not a digest. (beta.6 bakes the pelvis IMU mount `body_frame_quat 0,0,1,0` from on-robot fall data, **and** fixes IMU name resolution `pelvis`→`pelvis_imu` so the policy actually receives IMU data — the original fall was the policy running blind.)

---

## 0. Prerequisites (one-time, per host)

On the robot's **`/etc/phantomos/host-config.yaml`** (NOT the repo `_template`):

```yaml
images:
  mk2-loco-py:
    image: foundationbot/dma-ghost-wbc-inference:v0.1.0-beta.10-loco-aarch64
nodeLabels:
  foundation.bot/has-mk2-loco-py:    'true'
  foundation.bot/has-positronic:     'false'   # default is 'true' — MUST flip
  foundation.bot/has-locomotion:     'false'
  foundation.bot/has-sonic:          'false'
  foundation.bot/has-omni-wbc:       'false'
  foundation.bot/has-wolverine-loco: 'false'
```

Then re-run bootstrap so it reconciles labels and re-renders the manifest with the
pinned digest. Confirm the pod is up:

```bash
kubectl -n positronic get ds mk2-loco-py
kubectl -n positronic logs ds/mk2-loco-py | tail -40
```

---

## 1. Observe-only verification (no motion possible)

The console is on the robot's host network: **http://<robot-ip>:8088**
(or `kubectl -n positronic port-forward ds/mk2-loco-py 8088:8088`).

Verify, while `OBSERVE_ONLY=1`:
1. **IMU is plumbed** — startup log shows `config: … IMUs=['pelvis']` and
   `pelvis_imu_proj_gravity: rotated by quat wxyz=[0.0, 0.0, 1.0, 0.0]`. If the IMU
   name doesn't resolve, the policy runs **blind** on a default orientation — that
   was the original fall (fixed in beta.6, but confirm it here).
2. **Gravity / tilt telemetry is sane** — stand the robot level; tilt should be
   small (a few °, matching the robot's real lean), **not ~180°**. Tip it forward;
   tilt should grow and proj_gravity gain `+x`. A constant tilt regardless of pose
   means the IMU isn't being read.
3. **Joint positions/velocities** in `/status` match reality (units, signs, order).
4. Optionally set a token and drive the console (Home → Start → twist) and watch
   the *would-be* actions in telemetry — still no motion under `OBSERVE_ONLY=1`.

> The pelvis IMU mount (`body_frame_quat 0,0,1,0`, 180° about Y) is baked into the
> image from on-robot fall data. Do not arm until observe-only tilt looks correct.

### Enable the console to command (still safe)
Set a real `WEB_TOKEN` so you can issue start/twist (intent only, until armed):

```bash
kubectl -n positronic create configmap mk2-loco-py-config \
  --from-literal=WEB_TOKEN="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n positronic rollout restart ds/mk2-loco-py
```
Paste that token into the console's token box.

---

## 2. Arm + test the policy (supervised, robot secured)

**Two independent gates** stand between you and motion — keep both in hand:
`OBSERVE_ONLY` (manifest/env) and the `ENABLE_GATE` dead-man file. Have the
**E-STOP** button in the console ready (it's always accepted, token or not).

**Pre-flight:** robot on a stand / gantry or harnessed, area clear, E-stop reachable.

1. **Arm (ephemeral — auto-safes on next bootstrap reconcile, ideal for a test):**
   ```bash
   kubectl -n positronic set env ds/mk2-loco-py OBSERVE_ONLY=0
   kubectl -n positronic rollout status ds/mk2-loco-py
   ```
   The loop now *will* write `/desired` — but only once the dead-man exists.

2. **Open the dead-man gate.** Easiest: flip the **Enable gate** toggle in the
   console (reflects the real file; arming needs the token, disabling is always
   allowed). Or on the host (`/dev/shm` is a hostPath):
   ```bash
   touch /dev/shm/wolverine_enable     # engage
   ```
   (or `kubectl -n positronic exec ds/mk2-loco-py -- touch /dev/shm/wolverine_enable`)

3. **Test from the console:** Home → Start policy → nudge the **velocity sliders**
   (vx/vy ±1.0, wz ±0.5) in small increments. Watch tracking + stability.

4. **Stop, in increasing severity:**
   - zero the sliders / **Stop**;
   - **`rm /dev/shm/wolverine_enable`** — instantly cuts `/desired` (dead-man);
   - **E-STOP** in the console (always works);
   - **disarm:** `kubectl -n positronic set env ds/mk2-loco-py OBSERVE_ONLY=1`.

---

## 3. Making "armed" permanent (only after a clean test)

The ephemeral `set env` reverts to safe on the next bootstrap reconcile. To
persist commanding, edit the source and redeploy — a reviewed change:

```yaml
# manifests/base/mk2-loco-py/mk2-loco-py.yaml
- { name: OBSERVE_ONLY, value: "0" }   # was "1"
```
Commit, push, re-render/redeploy. The `ENABLE_GATE` dead-man still applies, so the
robot stays inert until `/dev/shm/wolverine_enable` exists.

---

## Notes
- **Policy maturity:** this is the `mk2_flat_quick` flat-terrain run — a bring-up
  policy, not terrain/robustness validated. Test tethered first.
- **Mutual exclusion:** mk2-loco-py shares the `/desired` plane with positronic /
  locomotion / sonic / omni-wbc / wolverine-loco — only one may be enabled per host.
