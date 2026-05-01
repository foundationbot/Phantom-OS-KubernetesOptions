# Bringing up a robot

A step-by-step guide for setting up a fresh Phantom-OS robot or
re-pairing an existing one. Written for operators who haven't touched
this repo before. You only need basic Linux shell skills — Kubernetes
knowledge is **not** required.

If you only want commands, jump to [Quick reference](#quick-reference)
at the bottom.

---

## What you're going to do

Each robot needs three things to run the Phantom-OS software:

1. **A Kubernetes cluster on the robot.** We use [k0s](https://k0sproject.io),
   a small single-binary distribution. The bootstrap script installs it
   for you.
2. **GitOps wired up.** ArgoCD watches this repo and pulls the right
   manifests for this robot. The bootstrap script installs ArgoCD too.
3. **Per-host configuration.** Things like "what's this robot called?",
   "which AI PC is paired with it?", and "which image versions should it
   run?" live in a single file at `/etc/phantomos/host-config.yaml`.

You'll fill in the host config first, then run the bootstrap script.
Both are interactive and idempotent — running them twice is safe.

---

## Step 1: Get the repo onto the robot

SSH into the robot and clone this repo somewhere persistent:

```bash
ssh user@<robot-ip>
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git \
  /opt/Phantom-OS-KubernetesOptions
cd /opt/Phantom-OS-KubernetesOptions
```

If the robot already has the repo, just `git pull` to grab the latest
scripts and templates:

```bash
cd /opt/Phantom-OS-KubernetesOptions
sudo git pull
```

---

## Step 2: Configure this host

Run the configuration wizard. It walks you through every per-host
setting and writes the result to `/etc/phantomos/host-config.yaml`.

```bash
sudo bash scripts/configure-host.sh
```

You'll be asked for three things:

### 2a. Robot identity

The wizard shows the available robot names (the directories under
`manifests/robots/`). Type the one matching this physical machine.
Names are lowercase by convention, but uppercase input is normalized.

```
== robot identity ==
  Available: ak-007 argentum mk09 mk11000010 mk11-generic
  e.g. mk09, ak-007, mk11000010
  robot []: mk09
```

If you don't know which one applies, ask the team.

### 2b. AI PC pairing

Each robot is paired with an "AI PC" reachable over Tailscale. The
operator UI talks to it for inference. Enter the URL with `http://`,
the IP, and port `5000`:

```
== AI PC pairing ==
  e.g. http://100.124.202.97:5000
  aiPcUrl []: http://100.124.202.97:5000
```

If you don't know the IP, run `tailscale status` on the robot and find
the host you've designated as its AI PC. (Each robot has its own —
they aren't shared.)

### 2c. Image tag overrides

Optional, but recommended for production robots. These pin the exact
versions of the locally-built images this robot should run. The wizard
shows defaults pulled from the closest matching template; press enter
to keep each one or type a new value.

```
== image tag overrides ==
  Press enter to keep each tag, or type a new value.
    e.g. 0.2.44-production-cu130 (positronic-control)
    e.g. 2026-04-30 (phantom-models — date-stamped)
    e.g. 585e58803318f5366d793986ad3e6129538b8a81 (operator-ui — git SHA)
  localhost:5443/positronic-control tag [0.2.44-production-cu130]:
  localhost:5443/phantom-models tag [2026-04-30]:
  foundationbot/argus.operator-ui tag [...]:
```

You can skip this whole section for a first bringup — the overlay's
default tags will apply, and you can set per-host tags later by
re-running `configure-host.sh`.

### Pre-filling from another robot

The repo no longer carries per-robot template files. To re-image or
duplicate an existing robot, copy its `host-config.yaml` from a
working sibling first:

```bash
ssh <other-robot> "sudo cat /etc/phantomos/host-config.yaml" \
  | sudo tee /etc/phantomos/host-config.yaml
sudo bash scripts/configure-host.sh    # wizard treats the existing
                                       # file as the seed; press enter
                                       # to keep each value or override
sudo bash scripts/bootstrap-robot.sh
```

If you have a tree of operator-supplied templates outside the repo
(e.g. `~/phantom-fleet-config/<robot>/host-config.yaml`), point
`--from-template` at that path:

```bash
sudo bash scripts/configure-host.sh --from-template ~/phantom-fleet-config/mk09
```

### Tip: review what was written

```bash
sudo bash scripts/configure-host.sh --show
sudo bash scripts/configure-host.sh --validate
```

---

## Step 3: Run the bootstrap script

Once `/etc/phantomos/host-config.yaml` is in place, hand the robot off
to the bootstrap script:

```bash
sudo bash scripts/bootstrap-robot.sh
```

It'll:

1. Check the host (OS, arch, disk, network ports).
2. Install dependencies (`docker.io`, `skopeo`, `k0s`, `terraform`,
   `argocd` CLI).
3. Bring up a single-node k0s cluster on this machine.
4. Configure container runtime (mirror, NVIDIA if a GPU is present).
5. Seed Docker Hub pull credentials so private images can be pulled.
6. Apply the operator-ui pairing ConfigMap from your host-config.
7. Install ArgoCD via Terraform and apply the GitOps app-of-apps.
8. Set the ArgoCD admin password (prompts you; default `1984`).
9. Inject the per-host image overrides into the live ArgoCD
   Application.
10. Run a final validation pass against the local image registry.

The whole thing takes 5–10 minutes on a fresh machine. The script
prints `PASS`, `FAIL`, and `SKIP` for each step. If anything fails it
stops and tells you exactly which step to fix.

The wizard will offer to run `bootstrap-robot.sh` for you when it
finishes, so step 2 and step 3 can be one command if you say "yes" at
the end:

```
  Run bootstrap-robot.sh now? [y/N]: y
```

---

## Step 4: Verify it's running

After bootstrap finishes, check the cluster:

```bash
# all pods should eventually be Running. ImagePullBackOff means
# step 5 (pull secrets) didn't pick up your DockerHub creds — see
# Troubleshooting below.
sudo k0s kubectl get pods -A

# the ArgoCD applications should be Synced + Healthy
sudo k0s kubectl -n argocd get applications

# operator-ui should have the AI_PC_URL you set
sudo k0s kubectl -n argus exec deploy/operator-ui -- env | grep AI_PC_URL
```

The operator UI is exposed on port `30080`:

```
http://<robot-ip>:30080
```

ArgoCD UI is on the cluster service `argocd-server` (not exposed by
default; port-forward to access):

```bash
sudo k0s kubectl -n argocd port-forward svc/argocd-server 8080:443 &
# then open https://localhost:8080
# username: admin
# password: 1984 (or whatever you set during bootstrap)
```

---

## Re-running things

Everything in this flow is **idempotent**. Re-run any of these as
often as you want:

| Command | When to use it |
|---|---|
| `configure-host.sh` | Change robot id, AI PC URL, or image tags |
| `configure-host.sh --show` | See what's currently configured |
| `configure-host.sh --validate` | Check the file is valid YAML |
| `bootstrap-robot.sh` | Re-apply config after editing host-config.yaml |
| `bootstrap-robot.sh --reset` | Wipe the cluster (purge then exit) |
| `bootstrap-robot.sh --<phase>` | Run just that one phase. Pass multiple `--<phase>` flags to run several. Available: `--deps --cluster --host --seed-pull-secrets --pairing --gitops --argocd-admin --image-overrides --dev-mounts --validate`. |

---

## Common scenarios

### Bringing up an existing robot (e.g. mk09) on a wiped machine

```bash
cd /opt/Phantom-OS-KubernetesOptions
sudo git pull

# Pull this robot's known-good config from a working sibling
ssh <other-mk09> "sudo cat /etc/phantomos/host-config.yaml" \
  | sudo tee /etc/phantomos/host-config.yaml
sudo bash scripts/bootstrap-robot.sh
```

If no sibling is reachable, run the wizard and fill values from the
team runbook:

```bash
sudo bash scripts/configure-host.sh
sudo bash scripts/bootstrap-robot.sh
```

### Bringing up a brand-new robot (no template)

```bash
sudo bash scripts/configure-host.sh   # answer the prompts
sudo bash scripts/bootstrap-robot.sh
```

The robot needs a directory under `manifests/robots/<name>/` and a
matching `gitops/apps/<name>/phantomos-<name>.yaml` — talk to the team
about getting those committed before bringing the robot online.

### Re-pairing a robot to a different AI PC

```bash
sudo bash scripts/configure-host.sh   # answer "y" to keep robot,
                                      # type the new aiPcUrl
sudo bash scripts/bootstrap-robot.sh  # re-applies the pairing CM
```

The bootstrap script will roll the operator-ui pod automatically so
the new value takes effect.

### Just changing image tags

```bash
sudo bash scripts/configure-host.sh   # press enter through robot
                                      # and aiPcUrl to keep them,
                                      # type new tags
sudo bash scripts/bootstrap-robot.sh --image-overrides
```

### Dev-mode hostPath mounts (developer machines only)

If you're running on a dev laptop or workstation and want to mount your
local source tree into the `positronic-control` pod (so code changes
are visible without rebuilding the image), add a `devMode:` block to
`/etc/phantomos/host-config.yaml`:

```yaml
devMode:
  positronic-control:
    source: /home/yourname/development/foundation/positronic_control
    mounts:
      - {host: /data,                          container: /data}
      - {host: /data2,                         container: /data2}
      - {host: /home/yourname/recordings,      container: /recordings}
      - {host: /home/yourname/trainground,     container: /trainground}
      - {host: /home/yourname/.cache/torch/hub, container: /root/.cache/torch/hub}
    privileged: true
```

Then re-run bootstrap:

```bash
sudo bash scripts/bootstrap-robot.sh
```

Phase 6.8 (`dev mounts`) injects a strategic-merge patch into the
live ArgoCD Application. The patch adds the volumes + volumeMounts and
(optionally) sets the container privileged. ArgoCD will not revert it.

**Rules / warnings:**

- All paths must be **absolute**. `~` is rejected — bootstrap runs as
  root, where `~` resolves to `/root` instead of your home.
- `privileged: true` grants the container `/dev` passthrough and full
  host access. Bootstrap warns loudly when you enable it. Use only on
  dev hardware you control.
- The single `source:` path is mounted at `/src` inside the container.
  Use the `mounts:` list for everything else.
- Removing the `devMode:` block from host-config and re-running
  bootstrap clears any previously injected dev mounts — the pod
  reverts to its production spec.

### Wiping a robot to start over

```bash
sudo bash scripts/bootstrap-robot.sh --reset
```

This stops k0s, purges the cluster, and exits. Your
`/etc/phantomos/` files (host-config, robot id, pairing) are
preserved, and so is on-disk hostPath data under `/var/lib/k0s-data/`,
`/var/lib/registry/`, and `/var/lib/recordings/`. To rebuild, just run
bootstrap again with no flag.

---

## Troubleshooting

### "must run as root"

Prefix every command with `sudo`. Bootstrap and configure both write
to `/etc/phantomos/` and need root.

### `error: could not determine robot identity`

You're on a fresh machine with no `/etc/phantomos/robot` yet, the
hostname doesn't match an overlay, and no `--robot` flag was given.
Either:

- Run `configure-host.sh` first to write
  `/etc/phantomos/host-config.yaml` (which sets the robot), or
- Pass `--robot <name>` to bootstrap directly.

### `manifests/robots/<name>/ not found`

The robot name you typed doesn't have an overlay in the repo. List
them:

```bash
ls manifests/robots/
```

If the name is missing, talk to the team about adding it.

### Pods stuck in `ImagePullBackOff`

The DockerHub credentials weren't seeded into the right namespaces.
Re-run only that phase:

```bash
sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets
```

If you don't have `~/.docker/config.json` on the robot, copy a working
`dockerhub-creds` Secret from another robot and re-run, or pass
`--dockerhub-secret-file <path>`.

### ArgoCD application stuck in `OutOfSync`

Sometimes the sync needs a nudge. Trigger one manually:

```bash
sudo k0s kubectl -n argocd patch app phantomos-<robot> \
  --type merge -p '{"operation":{"sync":{}}}'
```

Or use the ArgoCD UI (port-forward, see Step 4).

### Cluster won't start (`k0scontroller` failing)

Check the systemd journal:

```bash
sudo journalctl -u k0scontroller -n 200 --no-pager
```

Common causes: a previous k0s install left state behind. The cleanest
recovery is:

```bash
sudo bash scripts/bootstrap-robot.sh --reset   # purges + exits
sudo bash scripts/bootstrap-robot.sh           # rebuilds
```

### Operator UI shows "AI PC unreachable" / wrong IP

The Tailscale URL in your host-config is wrong, or operator-ui hasn't
been rolled since the change. Check:

```bash
sudo k0s kubectl -n argus exec deploy/operator-ui -- env | grep AI_PC_URL
```

If it shows the old value, force a rollout:

```bash
sudo k0s kubectl -n argus rollout restart deploy/operator-ui
```

If the IP is correct but you still can't reach it, verify Tailscale is
up on both sides:

```bash
tailscale status
tailscale ping <ai-pc-tailscale-name>
```

For a deeper troubleshooting tour, see [`trouble-shooting-guide.md`](./trouble-shooting-guide.md).

---

## What lives where

| Path | What it is |
|---|---|
| `/etc/phantomos/host-config.yaml` | Single per-host config file (robot id, AI PC URL, image tags, target branch, dev mode). The thing you edit. |
| `/etc/phantomos/robot` | One-line file with the robot name. Auto-written by bootstrap. |
| `/etc/phantomos/operator-ui-pairing.yaml` | ConfigMap manifest derived from `aiPcUrl`. Auto-written. |
| `/etc/phantomos/phantomos-app.yaml` | ArgoCD Application CR for THIS robot, rendered from `host-config-templates/_template/phantomos-app.yaml.tpl`. Auto-written. |
| `/var/lib/k0s-data/` | Database hostPath volumes (mongodb, redis, postgres). Survives `--reset`. |
| `/var/lib/registry/` | Local Docker registry storage. Survives `--reset`. |
| `host-config-templates/<robot>/host-config.yaml` | In-repo templates with each known robot's values (used to seed the wizard). |
| `host-config-templates/_template/phantomos-app.yaml.tpl` | Application CR template — bootstrap fills in robot/repo/branch and applies. |
| `scripts/configure-host.sh` | Interactive wizard for the host-config file. |
| `scripts/bootstrap-robot.sh` | Cluster bringup + apply config. |
| `manifests/robots/<robot>/` | Per-robot Kustomize overlay. Owned by the team, not by you. |

> The repo no longer carries `gitops/apps/<robot>/phantomos-<robot>.yaml` files. The Application CR is per-host (lives only on the cluster, never in git). See [`rfcs/0001-fleet-control-plane.md`](rfcs/0001-fleet-control-plane.md) for the longer-term direction.

---

## Quick reference

```bash
# typical first bringup
cd /opt/Phantom-OS-KubernetesOptions && sudo git pull
sudo bash scripts/configure-host.sh
sudo bash scripts/bootstrap-robot.sh

# typical re-pair / config change
sudo bash scripts/configure-host.sh
sudo bash scripts/bootstrap-robot.sh

# fast path: copy from a working sibling
ssh <other-robot> "sudo cat /etc/phantomos/host-config.yaml" \
  | sudo tee /etc/phantomos/host-config.yaml
sudo bash scripts/bootstrap-robot.sh

# wipe and rebuild
sudo bash scripts/bootstrap-robot.sh --reset
sudo bash scripts/bootstrap-robot.sh

# inspect
sudo bash scripts/configure-host.sh --show
sudo k0s kubectl get pods -A
sudo k0s kubectl -n argocd get applications
```
