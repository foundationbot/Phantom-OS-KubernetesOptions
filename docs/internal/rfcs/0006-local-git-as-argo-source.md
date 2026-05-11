# RFC 0006 — Local git repo as ArgoCD source

**Status:** sketch (Shape 3 chosen; details to be refined before
implementation)
**Companion:** `docs/rfcs/0005-auto-image-overrides-from-bundle.md`,
`docs/image-flow-and-registry-bootstrap.md`

## Problem

Today ArgoCD on every robot pulls manifests from
`https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git`
at `targetRevision: <branch>` (default `main`). Three real-world
pain points keep surfacing:

1. **Manifest/image bundle drift.** The image `.deb` is built at
   one revision; Argo polls a moving branch HEAD. When `main` is
   ahead of the .deb (or behind), tags in manifests and tags in
   `/var/lib/k0s/images/` diverge → ImagePullBackOff. Today's
   bringup hit exactly this: `imagePullPolicy: Always` on `main`
   bypasses containerd's local store, but the image .deb only
   helps `IfNotPresent` workloads.
2. **GitHub network dependency at the robot.** Air-gapped robots
   and robots behind paranoid corporate firewalls can't reach
   GitHub at all. Bootstrap requires argocd-repo-server to clone
   the public URL; no fallback.
3. **No atomic deploy unit.** A "release" is two artifacts (the
   image .deb and a git revision) that have to advance together
   to be safe — but nothing enforces it. Operators end up doing
   "build .deb at SHA `x`, scp, install, also remember to merge
   the same revision to `main`," and forget the second step.

Nice-to-have: rollback should be `dpkg -i <previous>.deb`, with
both manifests and image bundle reverting together.

## Proposal — Shape 3 (working tree at `/opt/.../` is the git source)

The control-plane `.deb` ships `/opt/Phantom-OS-KubernetesOptions/`
**including a `.git/` directory** that's a real git repository,
populated at .deb build time. ArgoCD's per-stack Application
points at `repoURL: file:///opt/Phantom-OS-KubernetesOptions` and
`targetRevision: HEAD` (or the branch name baked at build time).

The argocd-repo-server pod gets a read-only hostPath mount of
`/opt/Phantom-OS-KubernetesOptions` so it can clone the file://
URL. One extra hostPath mount on one pod; no new pods, no new
namespaces, no extra moving parts.

### Why Shape 3 over Shape 1 / Shape 2

| | Shape 1: bare repo at `/var/lib/phantomos-git/` | Shape 2: in-cluster git-http server | **Shape 3: `/opt/.../.git/` + hostPath** |
|---|---|---|---|
| Where the bytes live | `/var/lib/phantomos-git/repo.git` | hostPath PV behind a server pod | `/opt/Phantom-OS-KubernetesOptions/` (existing tree) |
| New pods | 0 | +1 (git-http server) | 0 |
| Files that double-duty | repo.git ↔ /opt/... working tree (drift risk) | repo.git only | working tree IS the repo (no drift) |
| Operator can `git log` after install | needs `cd /var/lib/phantomos-git && git log` | needs to know the URL | natural — `cd /opt/... && git log` |
| `dpkg -i` updates the source | postinst-driven extra step | postinst-driven extra step | inherent — `.deb` overwrites `/opt/...` including `.git/` |

Shape 3 wins because the `/opt/.../` tree is already what the .deb
maintains. Promoting it to "the git source" is conceptually one
extra step (`git init` at build time) rather than introducing a
parallel storage location.

### File and process flow

```
build host                               robot
─────────────────────────                ──────────────────────────
build-deb.sh:                            dpkg -i:
  rsync repo → stage/opt/...             unpacks stage/opt/... +
  cd stage/opt/...                       .git/ to /opt/...
  git init                               postinst:
  git add -A                               warn if /opt/.../.git
  git commit -m "phantomos-k0s @ vX"      modified by operator
  (resulting .git/ is part of            (detect via git status)
   the .deb payload)                     bootstrap-robot.sh:
                                           repoURL = file:///opt/...
                                           targetRevision = HEAD
                                           render Applications,
                                           apply.
                                         argocd-repo-server pod
                                         (with /opt/... hostPath
                                          mount, ro):
                                           git clone file:///opt/...
                                           render manifests/
                                           stacks/<stack>/
                                           apply to cluster
```

### Build-side changes (`scripts/build-deb.sh`)

Roughly 15 lines added. After the existing rsync into
`stage/opt/Phantom-OS-KubernetesOptions/`:

- `git -C stage/opt/Phantom-OS-KubernetesOptions init -q -b main`
- `git -C stage/... config user.email phantomos@foundation.bot`
- `git -C stage/... config user.name "phantomos build"`
- `git -C stage/... add -A`
- `git -C stage/... commit -q -m "phantomos-k0s ${VERSION}"` (commit
  message includes the .deb version + git rev-parse if running
  inside the source repo, for traceability)
- `git -C stage/... gc --aggressive --prune=now` (one-pack repo,
  keeps `.git/` small — typically a few MB even for a large tree)

The .deb's `Installed-Size` grows by whatever the packed
`.git/objects/pack/*.pack` weighs (small).

### Install-side changes (`packaging/deb/postinst`)

The current postinst (if any) gets one new responsibility: detect
operator edits to `/opt/.../.git/` or to tracked files in
`/opt/...` and warn. Specifically:

- If `git -C /opt/Phantom-OS-KubernetesOptions status --porcelain`
  is non-empty after the unpack, log `warning: /opt/... has local
  modifications; ArgoCD will reconcile against /opt/.../HEAD,
  ignoring uncommitted changes` and continue.
- This is only a warning because the unpack OVERWRITES the working
  tree, so `git status` should normally come back clean. Surfaces
  the case where someone hand-modified files in `/opt/...` between
  installs.

No automatic re-init of the repo on every install — the .deb's own
`.git/` is authoritative.

### Cluster-side changes (`terraform/main.tf`)

Argo Helm chart values get repo-server hostPath. ~10 lines:

```hcl
  values = [yamlencode({
    server = { service = { type = "NodePort" /* unchanged */ } }
    repoServer = {
      volumes = [{
        name     = "phantomos-source"
        hostPath = { path = "/opt/Phantom-OS-KubernetesOptions"
                     type = "Directory" }
      }]
      volumeMounts = [{
        name      = "phantomos-source"
        mountPath = "/opt/Phantom-OS-KubernetesOptions"
        readOnly  = true
      }]
    }
  })]
```

Read-only mount because argocd-repo-server only clones; it never
writes. This is also our defense against accidental tampering by
the repo-server itself.

### Bootstrap-side changes (`scripts/bootstrap-robot.sh`)

Two small changes:

1. `DEFAULT_REPO_URL` (line 3575) becomes
   `${DEFAULT_REPO_URL:-file:///opt/Phantom-OS-KubernetesOptions}`.
   The env-var override path stays for operators who want to flip
   back to remote-git without editing the script.
2. Default `targetRevision` becomes `HEAD` (or the branch name
   `main` since `build-deb.sh` does `git init -b main`). The
   existing host-config `targetRevision:` field still wins when set.

The `_gitops_render_app` template substitution at line 3657
already handles arbitrary URL strings — `file://...` works as-is
without code changes.

### Update / rollback workflow

- **Update:** build new .deb, scp to robot, `dpkg -i`. The unpack
  overwrites `/opt/.../.git/`, advancing HEAD to the new commit.
  Argo's next refresh (3-minute default poll) sees the new HEAD
  and reconciles. To force-refresh immediately:
  `kubectl -n argocd patch application phantomos-<robot>-core
  --type merge -p '{"metadata":{"annotations":
  {"argocd.argoproj.io/refresh":"hard"}}}'` — could be added to
  the postinst.
- **Rollback:** `dpkg -i previous-version.deb`. Same mechanism,
  HEAD moves backward, Argo reconciles backward.
- **No `git pull` involved on the robot ever.** Operators who try
  it get a no-op (no remotes configured) and a clean signal that
  this isn't how updates flow.

## Trade-offs and rejected alternatives

### Pure remote-git (status quo)

Already discussed in 0005. Pros: cheap fleet-wide updates via
`git push`, no .deb rebuild. Cons: drift, network dependency, no
atomic deploy unit.

### Shape 1: bare repo at `/var/lib/phantomos-git/`

Cleaner separation of "deployed source" from "/opt/... reference,"
but introduces a second copy that needs to stay in sync with the
.deb's working tree. Two storage paths means two failure modes
(repo.git stale relative to /opt/..., or vice versa). Not worth
the separation.

### Shape 2: in-cluster git-http server

Avoids the argocd-repo-server hostPath mount by introducing a
small git-server pod with its own hostPath mount. Same total
hostPath surface, +1 pod, +1 namespace, +1 service. Worth doing
only if the hostPath mount on argocd-repo-server is somehow
unacceptable (e.g. an OPA policy forbids it). Not the case here.

### Hybrid — both file:// and remote-git active simultaneously

Argo supports multiple Repositories per Project, so an operator
could declare two URLs and have Applications reference whichever.
Tempting but adds bootstrap complexity (which Application uses
which?) and confuses the "what's the current source of truth"
question. Reject for now; revisit if a strong use case emerges
(probably "operator wants to test a remote-git branch on top of a
locally-installed .deb").

## Coexistence with remote-git mode

Local-git is the default after this RFC, but remote-git remains a
first-class option for operators who want it (fleet ops who push
hot-fixes via GitHub; CI test machines that run against a feature
branch). Two ways to flip:

1. **Per-host:** new host-config field `gitSource: local | remote`
   (default `local`). When `remote`, bootstrap uses the existing
   `https://github.com/...` URL and `targetRevision: main` —
   exactly today's behavior. The wizard prompts for this.
2. **Per-build:** `DEFAULT_REPO_URL=https://github.com/...
   bootstrap-robot.sh` env-var override. Same as today.

Mixing within a fleet is fine — some robots local-git, some
remote-git, the host-config field is the source of truth per
host. Argo doesn't care; each Application's spec.source.repoURL
is independent.

## Open questions

1. **Is `targetRevision: HEAD` stable enough, or should bootstrap
   render with the literal commit SHA?** HEAD is a moving target
   inside the local repo (it changes on every `dpkg -i`). Argo
   handles HEAD fine, but pinning to the SHA gives more
   reproducibility — `kubectl get application -o yaml` shows
   exactly which revision is deployed without an extra `cd /opt &&
   git log`. Lean: pin to the commit SHA at bootstrap time;
   re-bootstrap re-pins after `dpkg -i` updates the working tree.
2. **Should the .deb's postinst trigger an Argo refresh?**
   Otherwise updates take up to 3 minutes to pick up. Lean: yes,
   `kubectl patch ... argocd.argoproj.io/refresh: hard` for each
   per-stack Application. Idempotent and cheap.
3. **What does `git gc --aggressive` cost at build time?**
   Probably negligible (single-commit repo), but worth measuring
   on the actual repo size.
4. **Read-only mount survives kubelet/Argo upgrades?** The Argo
   Helm chart's repoServer pod template can change between chart
   versions; a `volumeMounts` override needs to merge cleanly. May
   need to switch to a `strategicMergePatch` if Helm's value-merge
   doesn't append correctly.
5. **What about `host-config-templates/_template/phantomos-app.yaml.tpl`?**
   The template substitutes `{{REPO_URL}}` and `{{TARGET_REVISION}}`
   verbatim. With local-git, the rendered values are
   `file:///opt/Phantom-OS-KubernetesOptions` and a SHA — the
   template doesn't need to change. Confirmed by reading
   `bootstrap-robot.sh:3640-3680`.

## Validation plan

1. Build a local-git .deb, install fresh, confirm
   `git -C /opt/Phantom-OS-KubernetesOptions log --oneline` shows
   one commit at the expected version.
2. Bootstrap with default settings (local-git), confirm
   `kubectl get application phantomos-<robot>-core -o
   jsonpath='{.spec.source.repoURL}'` returns
   `file:///opt/Phantom-OS-KubernetesOptions`.
3. Confirm argocd-repo-server pod has the hostPath mount:
   `kubectl -n argocd describe pod argocd-repo-server-...
   | grep -A3 Mounts`. Confirm it can clone:
   `kubectl -n argocd logs argocd-repo-server-... | grep "fetched"`.
4. Pods come up Healthy.
5. `dpkg -i <newer>.deb`, confirm `/opt/.../.git/HEAD` advanced.
   Trigger refresh (manual or via postinst), confirm Argo
   reconciles to the new manifests within 30 s.
6. Rollback: `dpkg -i <older>.deb`, confirm HEAD moved back and
   Argo reconciles backward.
7. Flip to remote-git: edit host-config to `gitSource: remote`,
   re-run `bootstrap-robot.sh --gitops`, confirm Application
   repoURL updates to the GitHub URL.
8. Operator hand-edits a file in `/opt/...`, runs `dpkg -i`,
   confirms the warning fires and the .deb's version wins.
9. Air-gapped scenario: block egress, confirm bootstrap and Argo
   sync still complete (no GitHub round-trip).

## Out of scope

- Multi-tenant: pushing different revisions to different stacks.
  Today there's one .deb per build; one revision applies to all
  stacks. Per-stack revisions would need a richer template than
  today's flat `targetRevision`.
- Auth for remote-git mode (GitHub PAT, deploy keys). Existing
  bootstrap path doesn't handle private GitHub repos either; this
  RFC inherits that gap.
- Distributing the .deb itself (apt repo, S3, scp). The "how does
  the .deb get to the robot" question stays out of scope —
  RFC 0006 only covers what happens after.
- Mutating manifests on the robot directly without rebuilding the
  .deb. Operators wanting that should use remote-git mode or
  flip `gitSource: remote` + commit to a feature branch.

## Implementation footprint estimate

- `scripts/build-deb.sh`: ~15 lines added (git init/commit/gc).
- `packaging/deb/postinst`: ~5 lines added (status check + warn).
- `terraform/main.tf`: ~10 lines added (repoServer volumes/mounts).
- `scripts/bootstrap-robot.sh`: ~3 lines changed
  (`DEFAULT_REPO_URL`, default `targetRevision`, refresh patch).
- `scripts/configure-host.sh`: ~10 lines added (gitSource prompt
  + emit).
- `scripts/lib/host-config.py`: ~5 lines added (validate
  `gitSource: local|remote`, default `local`).
- Total: ~50 lines net. Sketch is plausible.
