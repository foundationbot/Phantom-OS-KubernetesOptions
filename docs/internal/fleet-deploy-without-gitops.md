# Fleet-driven deployment without GitHub-tracking gitops

Status: design discussion, not yet implemented.

This document captures an architectural option being considered for the
robot fleet: dropping the GitHub-tracking gitops loop in favour of a
fleet-software-driven model where a central service hands each robot the
manifest it should run, and the robot's k8s applies it without ever
pulling from git.

The current shape of the repo, the proposed change, the seams it touches,
and the trade-offs are documented below so the decision can be made
against full context.


## 1. What "gitops" means in this repo today

Phase 13 of `scripts/bootstrap-robot.sh` (`gitops()`, lines 3446–3593) does
three things:

1. Installs ArgoCD via the `terraform/` module.
2. Renders one ArgoCD `Application` CR per enabled stack from
   `host-config-templates/_template/phantomos-app.yaml.tpl`, substituting
   `{{ROBOT}}`, `{{STACK}}`, repo URL, branch, and `selfHeal` flag. The
   output lands at `/etc/phantomos/phantomos-app-<stack>.yaml` and is
   `kubectl apply`'d into the `argocd` namespace.
3. Cleans up legacy Applications from earlier eras (`root` app-of-apps,
   `phantomos-<robot>` umbrella) without cascade-deleting their
   workloads, so the per-stack Applications can claim existing resources.

After phase 13, ArgoCD does the actual work: it clones this repo, renders
`manifests/stacks/<stack>/` through kustomize, and applies the resulting
Deployments / DaemonSets / Services / etc. to the cluster. Phases 12 and
13 patch `spec.source.kustomize.{images,patches}` on the live Application
CRs, so per-host overrides from `host-config.yaml` (image tags, hostPath
mounts) get baked into ArgoCD's render.

ArgoCD then keeps watching: `git push` to the tracked branch → every
robot's ArgoCD picks the change up on its next ~3-minute reconcile tick.
With `selfHeal: true`, manual `kubectl edit`s also get reverted to match
git.


## 2. What "ArgoCD" actually buys us — and what it doesn't

A common conflation: "ArgoCD keeps my pods at the right version." It
doesn't, directly. **Kubernetes itself** (the Deployment / DaemonSet
controllers + kubelet) keeps running pods at whatever image tag is in the
spec object. Pin `image: foo:v1.2.3` in a manifest, `kubectl apply` it
once, and kubelet maintains v1.2.3 indefinitely — you can uninstall
ArgoCD afterward and the pod stays at v1.2.3.

ArgoCD's only job is keeping the **manifest objects in the cluster**
synchronized with the **manifests in git**. Specifically:

| Job | Done by |
|---|---|
| Pod at the specified image tag | kubelet + Deployment controller (k8s native) |
| New manifest in cluster after `git push` | ArgoCD |
| Revert of a manual `kubectl edit` | ArgoCD (when `selfHeal: true`) |
| Delete a resource that was removed from git | ArgoCD (prune) |
| First apply of the manifest tree | ArgoCD or `kubectl apply -k` — whichever you wire up |

If git-driven auto-sync is not desired, ArgoCD becomes mostly dead weight
on an edge robot.


## 3. Proposed alternative: fleet software hands the robot a manifest

The intent under discussion:

- **No git-pull from the cluster.** ArgoCD never reaches GitHub from the
  robot.
- **A central fleet service** knows which robot should run which pods at
  which versions.
- **The fleet service hands each robot a manifest** (or per-robot config)
  describing the desired state.
- **The robot's k8s applies what was handed to it**, period. Updates are
  initiated by the fleet, not by the robot polling git.


### Pieces that already exist

The repo is closer to this model than it might appear. Today's pieces map
cleanly onto a fleet-driven model:

| Piece today | Role in fleet-driven model |
|---|---|
| `manifests/base/*` and `manifests/stacks/*` | Catalog of "what could run on a robot." Stable, ships with the `phantomos-k0s` .deb to `/opt/Phantom-OS-KubernetesOptions/manifests/`. |
| `/etc/phantomos/host-config.yaml` | Per-robot manifest from the fleet: which stacks are enabled, image tags, hostPath mounts, node labels, dma-ethercat config. Already the source of truth for per-robot customization. |
| `phantomos-k0s-images-*.deb` (built by `scripts/build-images-deb.sh`) | Image bundle delivered to the robot out-of-band. Once installed, k0s imports tarballs into containerd at worker startup and pulls are satisfied locally — no DockerHub auth needed. |
| `scripts/lib/host-config.py inject-kustomize-block` | Renders host-config overrides into a kustomize overlay. Already does the per-host customization the fleet model needs. |

What's missing is a way to **apply** the host-config-overlaid manifests
without going through ArgoCD-against-git.


### What the change looks like in `bootstrap-robot.sh`

Phases 10/12/13 collapse into one:

| Today | Without ArgoCD |
|---|---|
| Phase 13: install ArgoCD via terraform; create Applications pointing at `manifests/stacks/<stack>` on `main` | Phase 13: render the kustomize overlay locally, baking host-config images/patches in |
| Phase 15: inject `kustomize.images` from host-config into the live Application CR | Phase 15: write `kustomize.images` into the rendered overlay at render time |
| Phase 16: inject `kustomize.patches` from host-config | Phase 16: write `kustomize.patches` into the rendered overlay at render time |
| ArgoCD reconciles every 3 min from git | One-shot `kubectl apply -k <overlay>` at end of phase 16 |
| Update flow: edit manifest → `git push` → robot picks up automatically | Update flow: fleet pushes new host-config.yaml + new .deb → trigger `bootstrap-robot.sh --reapply` |

Concrete sketch of the new phase 13:

```bash
# Phase 13 (replaces gitops + image-overrides + deployments-injection):
#   1. Render manifests/stacks/<enabled-stacks> through kustomize, with
#      images and patches from host-config.yaml baked in.
#   2. kubectl apply --prune -l phantomos.foundation.bot/managed=true
#      so removed-from-host-config workloads get deleted.
mkdir -p /var/lib/phantomos/rendered
for stack in $(host-config.py "$HOST_CONFIG" get-enabled-stacks); do
  python3 host-config.py "$HOST_CONFIG" \
    render-overlay "$REPO_ROOT/manifests/stacks/$stack" \
                   "/var/lib/phantomos/rendered/$stack"
done
kubectl apply -k /var/lib/phantomos/rendered/core
[ -d /var/lib/phantomos/rendered/operator ] && \
  kubectl apply -k /var/lib/phantomos/rendered/operator
```


### End-to-end flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Fleet software (centrally hosted)                              │
│  - Source of truth: which robot runs which pods at which tag    │
│  - Renders/pushes: host-config.yaml + image .debs per robot     │
└──────────────────────────────┬──────────────────────────────────┘
                               │ ssh/scp/rsync over Tailscale
                               │ (or other transport)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  Robot                                                          │
│  /etc/phantomos/host-config.yaml   ← fleet writes this          │
│  /var/lib/k0s/images/*.tar         ← fleet pushes .debs         │
│  k0s + manifests/                  ← stable, ships with the     │
│                                      phantomos-k0s .deb         │
│                                                                 │
│  Apply trigger (pick one):                                      │
│    - bootstrap-robot.sh --reapply (operator/fleet-triggered)    │
│    - systemd path-unit watching host-config.yaml                │
│    - small daemon on a Tailscale port for fleet pings           │
└─────────────────────────────────────────────────────────────────┘
```


## 4. Trade-offs

### What you'd gain

- **Simpler bootstrap.** No terraform install of ArgoCD, no Application
  CR rendering, no `phantomos-app-*.yaml` files to manage, no legacy-app
  migration logic.
- **~1 GB of RAM and a handful of pods back** on every robot
  (`argocd-server`, `argocd-repo-server`, `argocd-application-controller`,
  `argocd-redis`, `argocd-dex-server`, `argocd-applicationset-controller`,
  `argocd-notifications-controller`).
- **One less thing to debug** when a deploy doesn't land.
  `kubectl get pods` is the only state to inspect; no separate
  argocd-server UI / sync state machine.
- **Fully self-contained per-robot operation.** No need for argocd to
  reach git from the robot's network. Robots that are air-gapped or
  behind restrictive firewalls Just Work.
- **Fleet software is the single source of truth.** No "which branch is
  this robot tracking?" ambiguity.

### What you'd give up

- **Push-to-deploy from git.** Today: edit a manifest, `git push`, every
  robot picks it up on its next reconcile. Without ArgoCD: the fleet
  service has to push and trigger an apply on each robot. (For a small
  fleet with infrequent updates this is fine; for hundreds of robots
  with daily manifest churn, it's painful.)
- **Drift detection / `selfHeal`.** Manual `kubectl edit`s on a robot
  stay until something else clobbers them. Mitigation: re-run the apply
  on a periodic timer, or on every fleet-initiated update.
- **Centralized fleet visibility via argocd-server.** No single UI showing
  every robot's sync state at a glance. Mitigation: fleet software
  already knows what it pushed; optionally robots POST a heartbeat
  (`kubectl get pods -o jsonpath=...`) back.
- **Pruning is no longer automatic.** ArgoCD deletes resources that
  vanish from git. `kubectl apply -k` doesn't prune by default.
  Mitigation: `kubectl apply --prune -l phantomos.foundation.bot/managed=true`,
  or render the full set into a single multi-doc YAML and apply with
  `--prune --all`.


## 5. Variants

A few intermediate options, in case the all-or-nothing choice doesn't
fit:

### Variant A: drop ArgoCD entirely (the version this doc has been describing)

`bootstrap-robot.sh` does `kubectl apply -k <staged-overlay>` directly.
Phase 13 collapses as shown above.

### Variant B: keep ArgoCD, point it at a local directory

Init a git repo at `/var/lib/phantomos/manifests/` on the robot. Fleet
software pushes commits to it (via SSH, or by writing files + invoking
`git commit`). ArgoCD points at `file:///var/lib/phantomos/manifests` as
its `repoURL`.

- Pros: keeps ArgoCD's drift detection, selfHeal, and prune semantics.
- Cons: still ships the argocd-* pods on every robot; the local-git dance
  is awkward to operate; less savings vs. Variant A.

### Variant C: keep ArgoCD, point it at HTTPS-served manifests

Some ArgoCD source plugins / config-management plugins can pull from
HTTP(S). Fleet service serves per-robot rendered manifests at a stable
URL.

- Pros: keeps full ArgoCD semantics; no on-robot git repo.
- Cons: requires custom ArgoCD plugin work; least standard of the three.


## 6. Open questions

These need to be answered before any code change:

- **Transport.** How will manifests / config get from the fleet software
  onto each robot? Likely candidates: ssh/scp over Tailscale; HTTPS pull
  from a fleet endpoint.
- **Apply trigger.** What kicks off the re-apply after the fleet pushes
  an update? Likely candidates: operator-triggered `bootstrap-robot.sh
  --reapply`; systemd path-unit watching `host-config.yaml`; small daemon
  listening on a Tailscale port for fleet pings.
- **Pruning policy.** Use `kubectl apply --prune -l <label>` (requires a
  consistent management label on every resource we apply), or render to
  a single multi-doc YAML and apply with `--prune --all`?
- **Reapply cadence.** Should there be a timer that re-applies even when
  nothing changed (to revert drift), or only on explicit fleet trigger?
- **Heartbeat.** Do robots POST `kubectl get pods` summary back to fleet,
  so the fleet service can report fleet-wide health? If so, on what
  cadence and over what transport?
- **Fleet software identity.** Is the fleet service something already
  built / planned, or to-be-built? That affects how much glue the
  bootstrap script needs to provide vs. how much the fleet side handles.


## 7. Recommended next step

Variant A (drop ArgoCD entirely), with ssh-over-Tailscale transport and
operator-triggered `--reapply`, is the smallest, most direct path that
matches the stated intent. It can be implemented as:

1. Add `--reapply` flag to `bootstrap-robot.sh` that runs only the
   render-and-apply step, skipping host setup.
2. Replace `gitops()` with `apply_manifests()`: render kustomize overlays
   from `host-config.yaml`, `kubectl apply -k` each enabled stack,
   `kubectl apply --prune -l phantomos.foundation.bot/managed=true`.
3. Delete the `terraform/` ArgoCD Helm install path (or gate it behind
   `--legacy-argocd` for one transition release).
4. Remove `_gitops_*` helpers, the Application CR template, and the
   `phantomos-app-*.yaml` rendering machinery.
5. Add a label `phantomos.foundation.bot/managed=true` to every base
   manifest so prune works.

The fleet service piece — pushing host-config + .debs and triggering
`--reapply` — is left to the fleet team's preferred shape. The robot
side becomes a simple `apply -k` consumer.
