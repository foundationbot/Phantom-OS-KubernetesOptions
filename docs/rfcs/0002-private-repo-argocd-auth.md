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
7. **The cleartext credential is never persisted to robot disk** outside of
   etcd, and etcd is encrypted at rest. A non-root shell user on the robot
   cannot read the credential off the filesystem.
8. **Only ArgoCD's own ServiceAccounts can read the credential through the
   K8s API.** A user with a kubeconfig but without `cluster-admin` cannot
   `kubectl get secret -n argocd phantomos-kos-repo`.

## Threat model

Three surfaces leak the credential, and they need different defenses:

| # | Surface | Defense |
|---|---|---|
| 1 | A non-root user with kubectl reads `secrets/phantomos-kos-repo`. | RBAC lockdown + restrict who has a kubeconfig. AWS Secrets Manager does **not** help — ArgoCD requires a K8s `Secret`, so once it's in the cluster it's readable to anyone with `get` on it. |
| 2 | A non-root shell user on the robot reads `/etc/phantomos/argocd-repo-credential.yaml`. | Don't write the credential to disk — fetch from AWS at bringup and pipe straight into `kubectl apply -f -`. |
| 3 | Someone dumps etcd off disk (stolen robot, image clone). | k0s `EncryptionConfiguration` with a local AES-GCM key (KMS is overkill on edge). |

The ArgoCD UI is **not** a fourth surface: ArgoCD redacts `password` and
`githubAppPrivateKey` in repo API responses for non-admin callers.

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

### Source of truth: AWS Secrets Manager

The GitHub App private key + IDs live in **AWS Secrets Manager** as a single
JSON blob:

```json
// AWS Secrets Manager: phantomos/kos-repo-credential
{
  "githubAppID": "<app-id>",
  "githubAppInstallationID": "<install-id>",
  "githubAppPrivateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
}
```

Why AWS:

- One source-of-truth across the fleet. Rotation = update one AWS secret.
- CloudTrail audit on every `GetSecretValue`.
- The **operator** running `bootstrap-robot.sh` authenticates to AWS with
  their own creds (SSO, role assumption, whatever the org uses). **Robots
  themselves never get AWS credentials** — there's nothing on the robot for an
  attacker to pivot from.
- IAM scopes operator access to this one secret ARN with `secretsmanager:GetSecretValue`.

SSM Parameter Store (`SecureString`) is an acceptable substitute if the org
already uses it; the bootstrap fetch path is a one-line difference.

### How the credential reaches the cluster

Bootstrap fetches from AWS and **pipes straight into `kubectl apply -f -`**.
The credential is never materialized as a file on the robot:

```
aws secretsmanager get-secret-value \
    --secret-id phantomos/kos-repo-credential \
    --query SecretString --output text \
  | render-argocd-secret-yaml \                   # tiny shell/jq filter
  | kubectl apply -n argocd -f -
```

The intermediate `render-argocd-secret-yaml` step (a function inside
`bootstrap-robot.sh`, not a separate binary) wraps the JSON into the ArgoCD
`repository` Secret shape:

```yaml
# What kubectl apply sees on stdin — never written to disk
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
  githubAppID: "<app-id>"
  githubAppInstallationID: "<install-id>"
  githubAppPrivateKey: |
    ...
```

After this, the credential exists in exactly two places on the robot:

- **etcd** — encrypted at rest (see "etcd encryption" below).
- **`argocd-repo-server` pod memory** — unavoidable; ArgoCD has to use the key.

It does **not** exist on the robot's disk filesystem. A non-root shell user
cannot `cat` it.

### Fallback path: `--repo-credential-file`

For robots being bootstrapped from an operator machine that can't reach AWS
(air-gapped lab, contractor laptop without IAM), accept a flag:

```
sudo bash bootstrap-robot.sh --repo-credential-file ./creds.yaml
```

Bootstrap reads the file, applies it, **does not copy it onto the robot**.
The file lives only on the operator's machine. Bootstrap refuses files with
mode broader than `0600`. This path exists so we have an answer when AWS is
unreachable; the AWS path is the default and what we document in the
playbook.

### RBAC lockdown (closes threat #1)

Once the Secret is in the cluster, anyone with `get` on `secrets` in `argocd`
can read it. Defenses:

- **Kubeconfig hygiene.** k0s ships `/var/lib/k0s/pki/admin.conf` mode `0600`,
  owned by root. Audit and document: no non-root user gets a copy, ever. If a
  non-root operator needs cluster access, they get a scoped ServiceAccount
  kubeconfig, not admin.conf.
- **`Role` in `argocd` namespace** that grants `get,list,watch` on `secrets`
  to a specific list of ServiceAccounts (the ArgoCD components themselves)
  and **no humans**. Bind via `RoleBinding`, not `ClusterRoleBinding`.
- **Audit policy** logs `get`/`list` on `secrets` in `argocd`. Even if RBAC
  fails open, we see it.

These pieces ship as a small kustomize overlay applied during the same
bootstrap phase. Spelled out in detail in the bootstrap section below.

### etcd encryption at rest (closes threat #3)

k0s supports [`EncryptionConfiguration`](https://docs.k0sproject.io/stable/configuration/#specapiserverextraargs)
via `--encryption-provider-config`. Use AES-GCM with a 32-byte local key,
generated per-robot at bringup and stored at
`/var/lib/k0s/pki/encryption-config.yaml` mode `0600` root-owned. KMS-backed
providers are overkill on edge — there's no AWS KMS available offline, and
the threat being closed is "stolen robot disk" where a local key is fine
because the disk-stealer doesn't have root.

This step happens **before** k0s starts in the bootstrap phase ordering, so
the Secret is encrypted from the moment it's first written.

### `bootstrap-robot.sh` changes

Two new steps in the `gitops` phase
([../../scripts/bootstrap-robot.sh](../../scripts/bootstrap-robot.sh) — see
`gitops()` near line 1077), running **before** `_gitops_render_app` and the
`kubectl apply` of any Application CR:

```
gitops()
  → terraform install of argocd Helm           (existing)
  → _gitops_apply_repo_rbac                    (NEW)
       - kubectl apply Role + RoleBinding scoping secret reads in argocd
         to ArgoCD ServiceAccounts only
  → _gitops_apply_repo_credential              (NEW)
       - source = AWS Secrets Manager (default), or --repo-credential-file
       - AWS path:
            aws secretsmanager get-secret-value ...
              | _render_argocd_repo_secret_yaml
              | kubectl apply -n argocd -f -
         credential never touches disk; intermediate buffers are pipe-only
       - file path: read once, kubectl apply, never copy to robot
       - poll until `argocd repo list` shows status=Successful, or fail loud
  → _gitops_render_app                         (existing)
  → kubectl apply Application CR               (existing)
```

A separate earlier phase enables k0s etcd encryption-at-rest:

```
deps()
  → ...existing host prep...
  → _ensure_etcd_encryption_config             (NEW)
       - if /var/lib/k0s/pki/encryption-config.yaml missing,
         generate AES-GCM key, write file mode 0600 root:root
       - configure k0s to load it via --encryption-provider-config
       - this runs BEFORE k0s start, so all subsequent Secrets are
         encrypted from creation
```

Idempotency: `kubectl apply` of the Secret is naturally idempotent; the key
file is written once and reused on subsequent runs. Rotation flow:

- **Routine**: update the AWS secret value, run `bootstrap-robot.sh --gitops
  --rotate-repo-credential` against each robot. Same code path, just skips
  re-applying terraform / Application CRs.
- **Emergency**: revoke at GitHub first (fail-closed), then fan out the new
  AWS value. ArgoCD sits at "auth failed" for the gap, which is acceptable —
  workloads on disk keep running, only new reconciles stall.

`DEFAULT_REPO_URL` stays HTTPS; `phantomos-app.yaml.tpl` stays unchanged. The
match between the template's `repoURL` and the Secret's `url` field is what
binds them — ArgoCD picks the longest-prefix match.

### Migration for already-deployed robots

A short playbook (lives in [`../operations.md`](../operations.md), not this
RFC). Operator runs from a workstation with both AWS creds and a Tailscale
kubeconfig per robot:

1. Confirm AWS secret `phantomos/kos-repo-credential` exists and is current.
2. For each robot:
   ```
   bootstrap-robot.sh --gitops-repo-credential-only --context=<robot>
   # or, manually:
   aws secretsmanager get-secret-value --secret-id phantomos/kos-repo-credential \
       --query SecretString --output text \
     | _render_argocd_repo_secret_yaml \
     | kubectl --context=<robot> apply -n argocd -f -
   kubectl --context=<robot> -n argocd \
       annotate application phantomos-<robot>-core \
       argocd.argoproj.io/refresh=hard --overwrite
   argocd app get phantomos-<robot>-core   # expect Synced/Healthy
   ```
3. Apply the RBAC overlay (`_gitops_apply_repo_rbac`) the same way.
4. Etcd encryption can't be retrofit without restarting k0s — schedule per
   robot as a separate maintenance window. Until then, threat #3 is open
   only for robots that haven't been re-bootstrapped.
5. Only after **every** robot reports green on the credential step, flip the
   repo to private.

The annotation forces a fresh repo connection so we don't trust a cached
"public, no auth needed" state.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| One robot misses the migration step → silent reconcile failure after flip. | Pre-flip verification step in [../making-repo-private.md](../making-repo-private.md): enumerate every robot's `argocd app list` output. No flip until all green. |
| Non-root shell user reads the credential off disk. | Closed: AWS-fetch-at-bringup pipes straight to `kubectl apply -f -`; the credential never lives on the robot's filesystem. The fallback file path lives only on the operator's workstation. |
| Non-root user with kubeconfig reads the K8s Secret. | RBAC `Role` + `RoleBinding` in `argocd` ns scopes `secrets` access to ArgoCD ServiceAccounts only. `admin.conf` stays root-only. Audit policy logs any `get/list secrets`. |
| Stolen robot disk → etcd dump leaks the secret. | k0s `EncryptionConfiguration` (AES-GCM, local key at `/var/lib/k0s/pki/encryption-config.yaml` mode 0600 root). Configured before k0s start. |
| Operator's AWS creds compromised. | IAM scopes the operator's role to `secretsmanager:GetSecretValue` on this one ARN. CloudTrail flags unusual fetches. Routine GitHub App key rotation limits the window. |
| GitHub App private key gets baked into a robot disk image. | Closed: the key isn't on disk at all. Imaging never touches it. |
| Operator's `kubectl` context config gets stale → applies to wrong robot. | Migration playbook uses `--context=<robot>` explicitly + verifies `kubectl config current-context` before each apply. |
| ArgoCD UI exposes the credential to a non-admin user. | ArgoCD redacts `password` and `githubAppPrivateKey` for non-admin callers. Verify with a non-admin login as part of post-flip verification. |
| ArgoCD upgrade changes secret schema. | Pinned ArgoCD chart version in terraform; release notes review on bump. |

## Verification

- Unit-ish: a shellcheck-clean shim for `_gitops_apply_repo_credential` and
  `_render_argocd_repo_secret_yaml` with a fake `kubectl` and a fake `aws`
  CLI that records invocations. Assert: idempotency on re-run; failure when
  AWS returns no secret; the rendered YAML is structurally valid; the
  credential string never appears in any temp file or env-var dump from
  bootstrap (`set -x` log review).
- Disk-residue check on a test robot: after `bootstrap-robot.sh --gitops`,
  run `grep -r "BEGIN RSA PRIVATE KEY" /etc /var /tmp /root 2>/dev/null` —
  expect zero matches outside `/var/lib/k0s` (etcd, encrypted).
- RBAC test: `kubectl --as=system:serviceaccount:default:default -n argocd
  get secret phantomos-kos-repo` — expect `Forbidden`. Same with a
  non-cluster-admin human kubeconfig.
- Etcd encryption test: `etcdctl get /registry/secrets/argocd/phantomos-kos-repo`
  on the robot — expect ciphertext bytes, not the PEM.
- End-to-end on a test robot:
  1. Make a fresh fork of this repo and set it private.
  2. Provision a test GitHub App against the fork; store its key in a test
     AWS secret `phantomos-test/kos-repo-credential`.
  3. Run `bootstrap-robot.sh --gitops` with `AWS_PROFILE` pointed at a role
     that can read that secret.
  4. Confirm `argocd app list` shows `Synced/Healthy` for `phantomos-<robot>-core`.
  5. Push a trivial manifest change to the fork; confirm reconcile picks it up
     within the configured interval.
  6. Update the AWS secret with a new App key; run
     `bootstrap-robot.sh --gitops --rotate-repo-credential`; confirm
     reconciles continue and old key revocation at GitHub doesn't break sync.
  7. Revoke the App install; confirm `argocd-repo-server` logs surface 401 and
     `argocd app sync` fails clearly.
- Pre-flip on the real fleet: every robot reports `Synced/Healthy` against the
  still-public repo with the new Secret in place, proving the auth path is
  exercised before privacy is required.

## Open questions

1. GitHub App vs. PAT for v1 — depends on org-admin availability this week.
   Either way the AWS secret JSON shape and the bootstrap fetch path are the
   same; only the rendered YAML keys differ.
2. AWS Secrets Manager vs. SSM Parameter Store `SecureString` — pick whichever
   the org already uses. Bootstrap difference is a one-liner.
3. Etcd encryption key custody: per-robot local key (proposed) vs. a shared
   key fetched from AWS at bringup. Local is simpler and the threat being
   closed is "stolen disk" where a local-key blocks a non-root attacker
   anyway. Revisit if disk theft becomes a realistic operator threat.
4. Should the credential live in `argocd` namespace only, or also be replicated
   to a future shared namespace if other workloads need to pull from this
   repo? Defer until a second consumer appears.
5. ApplicationSet generators (RFC 0001 territory) will need the same Secret —
   confirm the label-based discovery is sufficient and we don't need an
   `ApplicationSet`-specific credential template.

## Critical files

- [../../scripts/bootstrap-robot.sh](../../scripts/bootstrap-robot.sh) — new
  `_gitops_apply_repo_rbac`, `_gitops_apply_repo_credential`,
  `_render_argocd_repo_secret_yaml`, and `_ensure_etcd_encryption_config`
  functions.
- [../../host-config-templates/_template/phantomos-app.yaml.tpl](../../host-config-templates/_template/phantomos-app.yaml.tpl)
  — unchanged; documented here for reference.
- New: `manifests/base/argocd-repo-rbac/` — kustomize overlay with the `Role`
  + `RoleBinding` scoping `secrets` access in `argocd` ns.
- New: AWS Secrets Manager entry `phantomos/kos-repo-credential` — JSON
  containing App ID / install ID / PEM (or `username`/`password` for PAT
  fallback).
- [../operations.md](../operations.md) — fleet migration playbook entry.
- [../making-repo-private.md](../making-repo-private.md) — sequencing doc that
  consumes this RFC.
