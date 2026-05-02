# RFC 0002 — ArgoCD repo auth for a private GitOps source

**Status:** Draft
**Author:** TBD
**Created:** 2026-05-01
**Companion doc:** [../making-repo-private.md](../making-repo-private.md)

## Problem

`foundationbot/Phantom-OS-KubernetesOptions` is going private (see companion
doc). When that flip happens, every robot's `argocd-repo-server` pod loses the
ability to clone this repo, because today it pulls anonymously over HTTPS:

- The per-stack `Application` CR is rendered from
  [../../host-config-templates/_template/phantomos-app.yaml.tpl](../../host-config-templates/_template/phantomos-app.yaml.tpl)
  with `repoURL: {{REPO_URL}}` substituted from
  `DEFAULT_REPO_URL` (`scripts/bootstrap-robot.sh:986`).
- That URL is `https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git`.
- No `Secret` of type `repository` exists in the `argocd` namespace today, so
  ArgoCD treats the URL as a public repo.

After the flip, `argocd app sync` returns `authentication required` and the
fleet stops reconciling silently — drifted state persists, new image tags don't
roll out, and operators discover it the next time they push a manifest change.

The host-side `git clone` paths (operator's shell during bringup) are
out-of-scope for this RFC; they're handled by docs because the operator's
machine already has personal git credentials.

## Goals

1. Every robot's ArgoCD can authenticate to the private repo using a credential
   it owns inside the cluster — no dependency on the operator's shell, the
   bootstrap host's git config, or Tailscale-tunneled `kubectl` calls at runtime.
2. **First-time bringup** (`bootstrap-robot.sh` on a fresh robot) provisions
   the credential before the first `Application` is applied, so the very first
   reconcile succeeds.
3. **Already-deployed robots** can be migrated in-place by an operator with
   Tailscale `kubectl` access — no SSH-to-robot step, no re-image.
4. The credential is **rotatable** without re-imaging robots, ideally without
   touching individual robots at all when only the secret value changes.
5. The credential is **scoped to this repo only**, read-only — compromise of
   one robot must not give write access to the GitOps source-of-truth.
6. The bootstrap path stays idempotent — re-running
   `bootstrap-robot.sh --gitops` does not break a working robot.

## Non-goals

- Migrating to SSH `repoURL`. HTTPS + PAT is simpler at fleet scale because
  the credential is a single string; SSH means per-robot keypair management.
- Multi-repo auth (e.g. consuming a second private repo). The pattern
  generalizes trivially but only one repo needs it today.
- Sealed-secrets / SOPS / external-secrets-operator integration. Layerable
  later; not needed for v1.
- Replacing the repo with a fleet control plane (RFC 0001). Orthogonal —
  whatever the source-of-truth ends up being, it'll need credentials.

## Proposed shape

### Credential: GitHub App, not a long-lived PAT

A **GitHub App** installation, scoped to this single repo with `Contents: Read`
permission, beats a fine-grained PAT for three reasons:

- **No human owner.** PATs expire when their owner leaves; App installations
  are owned by the org.
- **Short-lived tokens.** App installation tokens are minted for ~1 hour. ArgoCD
  has [first-class support](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/#github-app-credential)
  for refreshing them — the long-lived secret is the App's private key, not a
  bearer token that's hot in every cluster.
- **Audit.** App API calls are attributed to the App, not a person.

Fallback: if creating a GitHub App is blocked on org-admin paperwork, ship v1
with a fine-grained PAT scoped to `Contents: Read` on this one repo only, and
swap to the App later — the ArgoCD `Secret` shape is the only thing that
changes, and `bootstrap-robot.sh` already templates it.

### Where the credential lives on the robot

A single `Secret` in the `argocd` namespace, labeled
`argocd.argoproj.io/secret-type: repository` so `argocd-repo-server` picks it
up automatically:

```yaml
# /etc/phantomos/argocd-repo-credential.yaml — rendered at bootstrap, NOT in git
apiVersion: v1
kind: Secret
metadata:
  name: phantomos-kos-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/foundationbot/Phantom-OS-KubernetesOptions
  # GitHub App variant:
  githubAppID: "<app-id>"
  githubAppInstallationID: "<install-id>"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
  # PAT fallback variant (mutually exclusive with the three above):
  # username: x-access-token
  # password: <PAT>
```

Per-robot file location follows the same pattern as the rendered Application
CR (`/etc/phantomos/phantomos-app-<stack>.yaml`): on disk, not in git, applied
by bootstrap.

### How bootstrap learns the credential

The credential value is **not** in this repo and **not** in
`host-config.yaml` — both are world-readable on the robot. Two acceptable
sources, in order of preference:

1. **`/etc/phantomos/argocd-repo-credential.yaml` already present** (mode
   `0600`, owned by root). Bootstrap detects and applies it. This is how an
   operator pre-stages the credential during imaging or via a one-off SCP, and
   it's the path the migration playbook uses for already-deployed robots.
2. **Environment variable** at bootstrap invocation:
   `PHANTOMOS_KOS_REPO_CREDENTIAL=/path/to/secret.yaml sudo bash bootstrap-robot.sh`.
   Bootstrap copies it into place with mode `0600` then applies.

If neither is present, `bootstrap-robot.sh --gitops` **fails fast** with a
clear error pointing at this RFC. We deliberately do not prompt interactively
for an App private key on stdin — too easy to truncate, too easy to leak into
shell history.

### `bootstrap-robot.sh` changes

A new `_gitops_apply_repo_credential` step runs in the `gitops` phase
([../../scripts/bootstrap-robot.sh:1077](../../scripts/bootstrap-robot.sh)),
**before** `_gitops_render_app` and the `kubectl apply` of any Application CR:

```
gitops()
  → terraform install of argocd Helm  (existing)
  → _gitops_apply_repo_credential     (NEW)
       - locate credential file (env var, then /etc/phantomos/...)
       - chmod 0600, chown root:root
       - kubectl apply -n argocd -f <file>
       - poll: argocd-repo-server logs show "successfully connected"
                  or `kubectl -n argocd get secret phantomos-kos-repo`
                  exists and ArgoCD's repo connection-state CR is `Successful`
       - fail loudly with remediation hint on timeout
  → _gitops_render_app                (existing)
  → kubectl apply Application CR      (existing)
```

Idempotency: `kubectl apply` of the Secret is naturally idempotent;
re-rendering with the same content is a no-op. Rotation is covered by the same
code path — drop a new `argocd-repo-credential.yaml` in place and re-run
`bootstrap-robot.sh --gitops`, or `kubectl apply` it directly.

`DEFAULT_REPO_URL` stays HTTPS; `phantomos-app.yaml.tpl` stays unchanged. The
match between the template's `repoURL` and the Secret's `url` field is what
binds them — ArgoCD picks the longest-prefix match.

### Migration for already-deployed robots

A short playbook (lives in [`../operations.md`](../operations.md), not this
RFC):

1. Operator generates the credential YAML once.
2. For each robot, via Tailscale-routed `kubectl`:
   ```
   kubectl --context=<robot> apply -n argocd -f argocd-repo-credential.yaml
   kubectl --context=<robot> -n argocd \
       annotate application phantomos-<robot>-core \
       argocd.argoproj.io/refresh=hard --overwrite
   argocd app get phantomos-<robot>-core   # expect Synced/Healthy
   ```
3. Only after **every** robot reports green, flip the repo to private.

The annotation forces a fresh repo connection so we don't trust a cached
"public, no auth needed" state.

### Rotation

- **Routine rotation** (90d): mint a new App installation key, render a new
  `argocd-repo-credential.yaml`, fan out via the same migration playbook.
  Old key revoked at GitHub side after fan-out completes.
- **Emergency rotation** (suspected compromise): revoke key at GitHub first
  (fail-closed), then fan out the new one. ArgoCD will sit at "auth failed"
  for the gap, which is acceptable — manifests on disk keep running, only new
  reconciles stall.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| One robot misses the migration step → silent reconcile failure after flip. | Pre-flip verification step in [../making-repo-private.md](../making-repo-private.md): enumerate every robot's `argocd app list` output. No flip until all green. |
| Credential file leaks via host-config repo or backup. | File path is `/etc/phantomos/argocd-repo-credential.yaml`, mode `0600`, owned by root, **never** committed. Add to a `.gitignore` style check in bootstrap; refuse to apply files with broader perms. |
| GitHub App private key gets baked into a robot disk image. | Generate per-fleet, not per-image. Keep the key out of the imaging pipeline; inject at first boot via the env-var path. |
| Operator's `kubectl` context config gets stale → applies to wrong robot. | Migration playbook uses `--context=<robot>` explicitly + verifies `kubectl config current-context` before each apply. |
| ArgoCD upgrade changes secret schema. | Pinned ArgoCD chart version in terraform; release notes review on bump. |

## Verification

- Unit-ish: a shellcheck-clean shim for `_gitops_apply_repo_credential` with a
  fake `kubectl` that records `apply` invocations; assert idempotency on
  re-run, assert failure when credential file is missing or world-readable.
- End-to-end on a test robot:
  1. Make a fresh fork of this repo and set it private.
  2. Provision a test GitHub App against the fork.
  3. Run `bootstrap-robot.sh --gitops` with the test credential.
  4. Confirm `argocd app list` shows `Synced/Healthy` for `phantomos-<robot>-core`.
  5. Push a trivial manifest change to the fork; confirm reconcile picks it up
     within the configured interval.
  6. Revoke the App install; confirm `argocd-repo-server` logs surface 401 and
     `argocd app sync` fails clearly.
- Pre-flip on the real fleet: every robot reports `Synced/Healthy` against the
  still-public repo with the new Secret in place, proving the auth path is
  exercised before privacy is required.

## Open questions

1. GitHub App vs. PAT for v1 — depends on org-admin availability this week.
2. Should the credential live in `argocd` namespace only, or also be replicated
   to a future shared namespace if other workloads need to pull from this
   repo? Defer until a second consumer appears.
3. ApplicationSet generators (RFC 0001 territory) will need the same Secret —
   confirm the label-based discovery is sufficient and we don't need an
   `ApplicationSet`-specific credential template.

## Critical files

- [../../scripts/bootstrap-robot.sh](../../scripts/bootstrap-robot.sh) — new
  `_gitops_apply_repo_credential` step in the `gitops()` phase.
- [../../host-config-templates/_template/phantomos-app.yaml.tpl](../../host-config-templates/_template/phantomos-app.yaml.tpl)
  — unchanged; documented here for reference.
- New: `host-config-templates/_template/argocd-repo-credential.yaml.tpl` —
  template for operators to fill in (App ID / install ID / PEM, or PAT).
- [../operations.md](../operations.md) — fleet migration playbook entry.
- [../making-repo-private.md](../making-repo-private.md) — sequencing doc that
  consumes this RFC.
