# Quick start — run a positronic policy

> **CONFIDENTIAL.** This document and any corresponding documents shared
> in this drive contain highly sensitive confidential information of
> Foundation, including proprietary technical information that is
> strictly restricted. Please handle in accordance with the NDA, do not
> forward, and limit access to specifically authorized individuals only.

The positronic-control pod ships in **dev mode** by default: its
entrypoint is `sleep infinity`, so the pod stays alive but doesn't run
the control runtime. Operators (and devs iterating on policies) start
the actual workload under their own control with `positronic.sh`.

If you're installing on a robot for the first time, see
`docs/quickstart-install.md` first — this guide assumes the cluster is
up and the positronic-control pod is Running.

---

## Why sleep-infinity?

The container's args block dispatches on the `PHANTOM_CMD` environment
variable, sourced from the `positronic-config` ConfigMap in the
`positronic` namespace:

```yaml
# inside the manifest's args
if [ -n "${PHANTOM_CMD-}" ]; then
  exec ${PHANTOM_CMD}      # production-mode: run the policy
else
  exec sleep infinity      # dev-mode: stay alive, wait for kubectl exec
fi
```

So:

- **`PHANTOM_CMD` empty** → `sleep infinity`. Pod stays alive. Operator
  attaches via `kubectl exec` and runs the binary manually, with
  whatever args / debugger / wrappers they want.
- **`PHANTOM_CMD` set** → the pod's PID 1 is the policy binary.
  Crashes restart the pod (Kubernetes Deployment semantics). Same as
  production.

The choice is made via the `positronic-config` ConfigMap, NOT host-config
or the image. So switching between dev and prod modes is a single CM
patch + pod restart — no rebuild required.

---

## Inspect current state

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/positronic.sh status
```

Output sections:

- **Deployment / pod state** — Running / Pending / CrashLoopBackOff,
  image ref, restart count, age.
- **ConfigMap PHANTOM_CMD** — the value in the `positronic-config`
  ConfigMap (`(empty — pod runs sleep infinity)` if blank).
- **PHANTOM_CMD as seen by the pod** — read from inside the running
  container. Useful when the ConfigMap was updated but the pod
  hasn't restarted yet (ConfigMap projections update lazily).
- **PID 1 inside the pod** — what's actually running. `sleep infinity`
  in dev mode; the policy binary path in prod mode.

If the ConfigMap and the pod's view disagree, the pod hasn't rolled
yet — use `positronic.sh redeploy` to force it.

---

## Path 1 — interactive: exec into the pod

Keep the pod in sleep-infinity mode and run the policy by hand. Best
for iterative development, debugger attachment, or short experiments.

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/positronic.sh exec
```

Drops you into a `bash` inside the `positronic-control` container.
From there:

```bash
# inside the pod:
ls /opt/positronic/bin/             # find the binary
/opt/positronic/bin/positronic-control --help
/opt/positronic/bin/positronic-control --policy <policy-name> [args...]
```

Exit the shell (`Ctrl+D` or `exit`) to detach. The pod stays alive in
sleep-infinity mode — your shell session was just one of many possible
`exec` clients.

### Useful exec patterns

```bash
# Run a one-shot command without entering an interactive shell
sudo bash positronic.sh exec -- /opt/positronic/bin/positronic-control --version

# Tail a log file inside the container
sudo bash positronic.sh exec -- tail -f /var/log/positronic.log

# Run with environment overrides
sudo bash positronic.sh exec -- env DEBUG=1 /opt/positronic/bin/positronic-control --policy walking
```

---

## Path 2 — production-mode: set PHANTOM_CMD

Make the policy the pod's PID 1. The Deployment restarts the policy on
crash, and the pod is `Running` only while the policy is running
cleanly.

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/positronic.sh set-cmd \
  /opt/positronic/bin/positronic-control --policy walking
```

What this does:

1. Patches `positronic-config` ConfigMap with `PHANTOM_CMD=<your command>`.
2. Triggers a rollout restart of the `positronic-control` Deployment.
3. Pod comes back up; entrypoint dispatch sees `PHANTOM_CMD` set and
   `exec`s the policy.

Verify:

```bash
sudo bash positronic.sh status
sudo bash positronic.sh logs
```

The `status` output should now show the policy command in both "ConfigMap
PHANTOM_CMD" and "as seen by the pod" sections, and PID 1 should match.

To switch policies, just `set-cmd` again with a new command — the
ConfigMap is overwritten and the pod rolls. Takes ~5 seconds.

To go back to dev mode:

```bash
sudo bash positronic.sh clear-cmd
```

Clears `PHANTOM_CMD`, rolls the pod back to sleep-infinity.

---

## Watch logs

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/positronic.sh logs
```

Follows the pod's stdout/stderr (`kubectl logs -f`). Works whether the
pod is in dev or prod mode; in dev mode the output is empty
(sleep-infinity prints nothing), in prod mode it's the policy's output.

For init containers (`load-models`), pass the container name:

```bash
sudo bash positronic.sh logs -c load-models
```

---

## Common workflows

### Test a new policy build end-to-end

1. **On the build host** (or your laptop): build the positronic-control
   image with a new tag and `docker push` it to DockerHub under
   `foundationbot/positronic-control` (or the `foundationbot/phantom-cuda`
   ref the manifest points at). Then point the robot at the new tag:
   ```bash
   sudo bash positronic.sh redeploy foundationbot/phantom-cuda:0.2.46-dev.3
   ```
   This restarts the pod under the new image (pulled from DockerHub via
   the `dockerhub-creds` pull secret).
2. **On the robot**: pod restarts under the new image. By default it's
   in sleep-infinity. Either:
   - exec in and run the policy interactively (Path 1).
   - `set-cmd` to make it the pod's PID 1 (Path 2).
3. Iterate on policy args inside the pod until happy.
4. Update host-config's `images.positronic-control.image` field, run
   `bootstrap-robot.sh --image-overrides` to pin the new tag, then
   `set-cmd` to make the policy the PID 1.

### Switch between policies on the fly

`set-cmd` is fast (~5 sec for the restart). Common during dev:

```bash
sudo bash positronic.sh set-cmd /opt/positronic/bin/positronic-control --policy locomotion
# observe in logs, decide next experiment
sudo bash positronic.sh set-cmd /opt/positronic/bin/positronic-control --policy state-estimator
```

### Pin a policy in host-config for production robots

Right now `PHANTOM_CMD` is set imperatively via `set-cmd`. To pin a
policy declaratively per robot, edit the `positronic-config` ConfigMap
in `manifests/base/positronic/configmap.yaml` (or add a kustomize
patch in the robot's host-config) — but most ops flows keep this in
the ConfigMap and use `set-cmd` for changes.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod in `Init:0/1` forever | phantom-models image not in containerd. Check `/var/lib/k0s/images/foundationbot-phantom-models_*.tar` exists; if missing, the bundle didn't extract. Re-run the install wrapper. |
| Pod `CrashLoopBackOff` after `set-cmd` | Your command exited non-zero. Kubernetes restarts the pod and re-runs it. Either fix the command or `clear-cmd` to fall back to sleep-infinity for debugging. |
| `positronic.sh exec` fails with `container not found` | Pod isn't Running yet. Check `positronic.sh status` — if it's `Init:`, wait for the load-models init container to finish. |
| GPU not visible inside the pod | `positronic.sh gpu-test` to verify CUDA libraries are mounted in. Most common cause: the NVIDIA runtime isn't registered with k0s containerd. Run `sudo bash scripts/configure-k0s-nvidia-runtime.sh` from the repo and restart k0s. |
| `set-cmd` doesn't take effect | The ConfigMap update is async — `positronic.sh status` will show ConfigMap vs. pod views diverging. Pod restarts automatically on the rollout, but if it didn't, use `positronic.sh redeploy`. |
| Policy can't find data partition / camera config | The positronic-control pod mounts hostPaths from the host's filesystem. Check `host-config.yaml`'s `deployments.positronic-control.mounts` block — that's where mount points like `/data`, `/data2`, `/recordings`, torch cache, etc. are configured. |

---

## Reference: `positronic.sh` subcommands

```
status                 show pod + ConfigMap + PID 1 state
exec [-- <cmd>]        bash into the pod, or run <cmd> non-interactively
logs [-f] [-c <cont>]  show / follow pod logs (optionally for init containers)
set-cmd <command...>   set PHANTOM_CMD in the ConfigMap, rollout the pod
clear-cmd              clear PHANTOM_CMD, rollout the pod back to sleep-infinity
push-image <ref>       tag + docker push to foundationbot/positronic-control on DockerHub, rollout
redeploy               rollout restart with no image change
track-branch <branch>  flip Argo Application targetRevision (remote-git mode only — see RFC 0006)
argo-pause             pause Argo auto-sync on the core stack
argo-resume            re-enable Argo auto-sync
gpu-test               run a small CUDA workload inside the pod to confirm GPU is wired up
teardown               delete the Deployment (drastic; recreated on next Argo sync)
help                   full subcommand list with options
```

All commands accept `--robot <name>` to disambiguate when multiple
robot prefixes exist in the cluster. Default robot name is read from
`/etc/phantomos/host-config.yaml`.
