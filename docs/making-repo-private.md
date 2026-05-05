# Making this repo private

**Status:** Plan
**Created:** 2026-05-01

This repo (`foundationbot/Phantom-OS-KubernetesOptions`) is currently public. It
is the source-of-truth GitOps repo that ArgoCD on each robot pulls from, and
the bootstrap script clones it anonymously over HTTPS. Flipping visibility to
private is a one-click GitHub action, but several places assume *unauthenticated*
read access — those will break the moment the repo goes private if not addressed
first. This doc sequences the prep work, the flip, and the cleanup so robots in
the field don't fail to reconcile.

## What breaks when it goes private

There are **two distinct clone paths** and they have different answers:

**A. Host-side `git clone` from the operator's shell** — used by
[../README.md](../README.md) (quickstart), [bringing-up-a-robot.md](bringing-up-a-robot.md),
[trouble-shooting-guide.md](trouble-shooting-guide.md), and any plain `git clone`
step inside [../scripts/bootstrap-robot.sh](../scripts/bootstrap-robot.sh). **If
the operator already has git credentials configured on the deploy machine**
(credential helper, `~/.netrc`, SSH key, `gh auth login`), this path keeps
working with no code change. We only need to update the docs to say "you'll need
read access — `gh auth login` or set up an SSH key first."

**B. ArgoCD's in-cluster reconciliation loop** — this is the path that actually
breaks. The `argocd-repo-server` pod runs inside the k0s cluster on the robot
and has **no access to the host operator's git credentials**. It clones the
`repoURL` baked into each per-host Application CR
([../host-config-templates/_template/phantomos-app.yaml.tpl](../host-config-templates/_template/phantomos-app.yaml.tpl))
and the URL `bootstrap-robot.sh` registers
([../scripts/bootstrap-robot.sh](../scripts/bootstrap-robot.sh) — see
`DEFAULT_REPO_URL`) anonymously today. The moment the repo goes private, every
robot's GitOps sync starts failing with 401 until ArgoCD has its own credential.

Path B is designed in [rfcs/0002-private-repo-argocd-auth.md](rfcs/0002-private-repo-argocd-auth.md).
Path A is a docs touch-up.

## Other downstream considerations

- Public forks (if any) get detached but stay public — check
  `gh api repos/foundationbot/Phantom-OS-KubernetesOptions/forks`.
- GitHub Actions minutes: private repos consume from the org's quota
  (public repos are unmetered).
- GitHub Pages / external doc links break if any are published from this repo
  (none observed).
- Search/SEO links die — fine, that's the point.

## Plan

### 1. Pre-flip: give ArgoCD a credential (the actual blocker)

Implement [rfcs/0002-private-repo-argocd-auth.md](rfcs/0002-private-repo-argocd-auth.md).
At a high level:

- Provision a fine-grained PAT (or GitHub App installation token) scoped to
  `Contents: read` on this repo only.
- Land an ArgoCD `repository` Secret on every cluster (new + already-deployed).
- Update [../scripts/bootstrap-robot.sh](../scripts/bootstrap-robot.sh) to
  install the secret before creating the per-stack `Application` CRs.
- For robots already in the field: apply the new ArgoCD `Secret` to each
  cluster (via Tailscale + `kubectl`) and confirm `argocd repo list` shows
  `Successful` *before* flipping visibility. This is the riskiest step — losing
  GitOps on a deployed robot means a manual recovery trip.

### 1b. Docs touch-up (path A)

Update [../README.md](../README.md), [bringing-up-a-robot.md](bringing-up-a-robot.md),
[trouble-shooting-guide.md](trouble-shooting-guide.md),
[archive/architecture-decision-argocd-topology.md](archive/architecture-decision-argocd-topology.md),
and the top-level `kos-implmentation-plan-v1.md` to add a "you'll need read
access — run `gh auth login` or configure an SSH key first" prerequisite. The
`git clone` lines themselves can stay as-is.

### 2. Flip visibility

GitHub UI: **Settings → General → Danger Zone → Change repository visibility →
Make private**. Or:

```bash
gh repo edit foundationbot/Phantom-OS-KubernetesOptions \
    --visibility private \
    --accept-visibility-change-consequences
```

### 3. Post-flip verification

- `gh repo view foundationbot/Phantom-OS-KubernetesOptions --json visibility`
  returns `private`.
- On a deployed robot:
  `kubectl -n argocd get applications -o wide` shows `Synced/Healthy`;
  `argocd app sync phantomos-<robot>-core` succeeds; check `argocd-repo-server`
  logs for 401s.
- Anonymous `git clone https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git`
  from a fresh shell **fails** (confirms private).
- Authenticated `git clone` (via PAT or SSH deploy key) **succeeds**.
- Re-run `bootstrap-robot.sh` end-to-end on a spare/test machine to confirm
  onboarding still works.
- `gh api repos/foundationbot/Phantom-OS-KubernetesOptions/forks` — review and
  notify any forkers if relevant.

### 4. Housekeeping

- Rotate the PAT/deploy key on a schedule; document the rotation procedure.
- Audit org members + outside collaborators on the repo so the right humans
  still have read/write.
- If GitHub Actions runs in this repo, confirm minute consumption is acceptable
  under the private quota.
