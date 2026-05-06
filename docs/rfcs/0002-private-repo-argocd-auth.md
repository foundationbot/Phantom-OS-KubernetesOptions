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

## v1 vs. v2 scope

**v1 (this RFC, ships now):** file-based credential on disk, mode `0600`
root-owned, applied by bootstrap. K8s RBAC + ArgoCD user RBAC + etcd
encryption-at-rest all land in v1 because they're the defenses that actually
gate threats #1, #3, #4 below — those don't get easier in v2.

**v2 (deferred):** swap the file source for AWS Secrets Manager (or SSM
`SecureString`) so the credential never touches the robot's disk. Sketched
in [§ "v2 deferred: AWS-source"](#v2-deferred-aws-source) for context but not
implemented in this RFC.

## Threat model

Five surfaces leak the credential or grant unintended access. They need
different defenses, and the v1/v2 split is about *which* surface gets closed
when.

| # | Surface | v1 defense | v2 defense |
|---|---|---|---|
| 1 | A non-root user with kubectl reads `secrets/phantomos-kos-repo`. | K8s `Role`/`RoleBinding` in `argocd` ns scopes `get/list/watch secrets` to ArgoCD ServiceAccounts only. `admin.conf` stays root-only. | (unchanged — same defense) |
| 2 | A non-root shell user on the robot reads `/etc/phantomos/argocd-repo-credential.yaml`. | File mode `0600`, owner `root:root`. Bootstrap refuses to apply broader perms. Acceptable because root-only access is the same bar as `admin.conf`. | Closed: AWS-fetch pipes into `kubectl apply -f -`; nothing on disk. |
| 3 | Someone dumps etcd off disk (stolen robot, image clone). | k0s `EncryptionConfiguration` with an AES-CBC local key at `/var/lib/k0s/pki/encryption-config.yaml`. | (unchanged) |
| 4 | A logged-in ArgoCD UI/CLI user with `admin` rights makes destructive cluster changes (delete app, delete cluster, rotate creds). | Two non-admin ArgoCD accounts: `operator` (`role:readonly`) and `fleet-operator` (sync + runtime edits + scale, no creds read, no cluster delete). `admin` reserved for breakglass. | (unchanged) |
| 5 | ArgoCD UI exposes credential value to non-admin user. | ArgoCD natively redacts `password` and `githubAppPrivateKey` for non-admin callers; verified by post-bringup test. | (unchanged) |

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

### Source of truth (v1): credential file on disk

The credential is a YAML file at a fixed path on the robot:

```
/etc/phantomos/argocd-repo-credential.yaml      # mode 0600, root:root
```

Contents (GitHub App variant — preferred):

```yaml
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
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
```

PAT fallback variant (used if a GitHub App isn't available yet):

```yaml
stringData:
  type: git
  url: https://github.com/foundationbot/Phantom-OS-KubernetesOptions
  username: x-access-token
  password: <PAT>
```

Provisioning paths, in order of preference:

1. **`--repo-credential-file <path>` flag.** Operator passes a path during
   bootstrap; the file is read once and applied. Default behavior: bootstrap
   copies the file to `/etc/phantomos/argocd-repo-credential.yaml` mode `0600`
   so re-runs (rotation, repair) don't need the operator to re-supply it.
   Pass `--repo-credential-file - --no-persist-credential` to apply from
   stdin without writing to disk (rare; mostly for one-shot rotation).
2. **File already at `/etc/phantomos/argocd-repo-credential.yaml`.** Bootstrap
   detects, validates mode is `0600`, applies. This is the steady-state path
   on subsequent re-runs and the migration path for already-deployed robots
   (operator SCPs the file once).

Bootstrap refuses to apply a credential file with mode broader than `0600` or
ownership other than `root:root`, and refuses to start k0s before etcd
encryption-at-rest is configured (see § "etcd encryption at rest" below).

The file is **never** committed to git. Add a guard to bootstrap that fails
if it detects the file inside a git work tree.

### v2 deferred: AWS-source

When we move to AWS Secrets Manager (sketch only — not implemented in v1):

- A single AWS secret `phantomos/kos-repo-credential` holds the App ID +
  install ID + PEM as a JSON blob.
- The operator running `bootstrap-robot.sh` authenticates to AWS with their
  own creds; robots themselves never get AWS credentials.
- Bootstrap pipes `aws secretsmanager get-secret-value` → render-shim →
  `kubectl apply -f -`. Nothing on disk.

This closes threat #2 entirely. Until v2 ships, threat #2 is bounded by file
permissions: a non-root shell user cannot read the file, and `admin.conf` is
already root-only, so the bar is the same as for cluster admin.

### Kubernetes RBAC lockdown (closes threat #1)

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

These pieces ship as a small kustomize overlay applied during the
`gitops` bootstrap phase. Spelled out in detail in the bootstrap section
below.

### ArgoCD account RBAC (closes threat #4)

Today the cluster has only one ArgoCD account: `admin`. Bootstrap sets the
password via [argocd_admin()](../../scripts/bootstrap-robot.sh#L2057) and
that's the only login. v1 introduces two additional accounts so day-to-day
operators don't log in as `admin`:

| Account | ArgoCD role | Intended user |
|---|---|---|
| `admin` | `role:admin` (built-in) | Breakglass only. Password lives in 1Password / sealed envelope. |
| `operator` | `role:readonly` (built-in) | Anyone watching the fleet. UI / `argocd app get`, no mutating actions. |
| `fleet-operator` | `role:fleet-operator` (custom — defined below) | On-call. Sync apps, restart workloads, scale up/down. Cannot delete the cluster, cannot read repo creds. |

#### `role:fleet-operator` policy

ArgoCD RBAC uses Casbin; explicit `deny` rules override `allow`. Order in
`argocd-rbac-cm.policy.csv`:

```
# allows
p, role:fleet-operator, applications, get, */*, allow
p, role:fleet-operator, applications, sync, */*, allow
p, role:fleet-operator, applications, action/*, */*, allow      # exec resource actions (restart, scale via Lua)
p, role:fleet-operator, applications, override, */*, allow      # override sync to roll back
p, role:fleet-operator, repositories, get, *, allow
p, role:fleet-operator, projects, get, *, allow
p, role:fleet-operator, logs, get, */*, allow
p, role:fleet-operator, exec, create, */*, deny                 # no kubectl-exec into pods
p, role:fleet-operator, applications, delete, */*, deny         # no app delete
p, role:fleet-operator, clusters, *, *, deny                    # no cluster add/edit/delete
p, role:fleet-operator, repositories, create, *, deny
p, role:fleet-operator, repositories, update, *, deny
p, role:fleet-operator, repositories, delete, *, deny
p, role:fleet-operator, accounts, *, *, deny                    # no account/password mgmt
p, role:fleet-operator, certificates, *, *, deny
p, role:fleet-operator, gpgkeys, *, *, deny

# bind users to roles
g, operator,        role:readonly
g, fleet-operator,  role:fleet-operator
```

Two callouts on what fleet-operator can/cannot do:

- **"Read of creds not allowed"** has two layers. The ArgoCD layer (`repositories,
  get`) returns the `Repository` object but ArgoCD redacts `password` /
  `githubAppPrivateKey` fields for non-admin callers natively — we get this
  for free. The K8s layer (`kubectl get secret`) is closed by the namespace
  `Role` in the previous section: fleet-operator's kubeconfig (if any) does
  not bind to that Role.
- **"Scaling up/down allowed"** is split across two surfaces:
  - **Via ArgoCD UI**: handled by `applications, action/*` if we install the
    standard Argo `apps/Deployment` and `apps/StatefulSet` actions, which
    include scale up/down as Lua-defined actions.
  - **Via direct `kubectl scale`**: requires K8s RBAC. v1 issues a
    `fleet-operator` ServiceAccount + kubeconfig with `view` ClusterRole
    (read everything except secrets — `secrets` is excluded from the built-in
    `view` role) **plus** a small Role granting `update`/`patch` on
    `*/scale` subresources (`deployments/scale`, `statefulsets/statefulsets`,
    `replicasets/scale`). Explicitly **no** `delete` on namespaces, nodes,
    PVs, CRDs, ClusterRoleBindings.

#### Account passwords

ArgoCD per-account passwords live in `argocd-secret` under
`accounts.<name>.password` and `accounts.<name>.passwordMtime`. The existing
[`argocd_admin()`](../../scripts/bootstrap-robot.sh#L2057) bcrypt + patch
logic is refactored into `_argocd_set_account_password <account>` and called
three times: `admin`, `operator`, `fleet-operator`. Bootstrap prompts for
each interactively (with the same default-`1984` first-bringup convenience),
and the existing `--argocd-admin` flag becomes `--argocd-users` to cover
rotation across all three.

#### `argocd-cm` accounts wiring

ArgoCD only lets you log in as a non-`admin` account if `argocd-cm` declares
it:

```yaml
# argocd-cm patch (applied via bootstrap)
data:
  accounts.operator: login
  accounts.operator.enabled: "true"
  accounts.fleet-operator: login
  accounts.fleet-operator.enabled: "true"
```

Both pieces (`argocd-cm` accounts list + `argocd-rbac-cm` policy) ship as a
single kustomize overlay under `manifests/base/argocd-rbac/`, applied during
the `gitops` phase before `_argocd_set_account_password` runs.

### etcd encryption at rest (closes threat #3)

k0s supports [`EncryptionConfiguration`](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
via `--encryption-provider-config` on kube-apiserver. We use **AES-CBC** with
a 32-byte random key generated locally at first bringup:

```yaml
# /var/lib/k0s/pki/encryption-config.yaml — mode 0600 root:root
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - aescbc:
          keys:
            - name: phantomos-v1
              secret: <base64(head -c 32 /dev/urandom)>
      - identity: {}
```

Why AES-CBC over the alternatives:

- **`aesgcm`** requires per-~200k-write key rotation; too operationally heavy.
- **`secretbox`** is fine but offers no advantage over AES-CBC for our threat
  model.
- **`kms`** envelope encryption is the cloud answer; on edge there's no KMS
  to talk to offline. The local-key approach blocks "stolen disk" because the
  attacker doesn't have root on a running k0s — they have the disk's bytes.

The key is generated **per robot** (not per fleet) at first bringup. Lose the
key → lose etcd readability, so bootstrap also writes a backup copy at
`/etc/phantomos/etcd-encryption-key.bak` mode `0600` root-owned, and the
operations runbook documents how to recover from a partial-disk loss.

Order matters: this step happens **before** k0s starts in the bootstrap phase
ordering, so every Secret (including the repo credential) is encrypted from
the moment it's first written. Retrofit on already-deployed robots requires a
k0s restart and a one-time read-and-rewrite of existing Secrets — covered in
the migration playbook.

### `bootstrap-robot.sh` changes

Phase ordering with new steps (NEW marked):

```
deps()
  → ...existing host prep...
  → _ensure_etcd_encryption_config             (NEW, BEFORE k0s start)
       - if /var/lib/k0s/pki/encryption-config.yaml missing,
         generate AES-CBC key, write file mode 0600 root:root
       - back up key to /etc/phantomos/etcd-encryption-key.bak (0600 root)
       - configure k0s to load it via --encryption-provider-config
       - this runs BEFORE k0s start, so all subsequent Secrets are
         encrypted from creation

gitops()
  → terraform install of argocd Helm           (existing)
  → _gitops_apply_secret_rbac                  (NEW)
       - kubectl apply Role + RoleBinding (manifests/base/argocd-secret-rbac/)
         scoping secret reads in argocd to ArgoCD ServiceAccounts only
  → _gitops_apply_argocd_user_rbac             (NEW)
       - kubectl apply patches (manifests/base/argocd-rbac/) on
         argocd-cm (accounts.operator/.fleet-operator) and
         argocd-rbac-cm (policy.csv with role:fleet-operator)
  → _gitops_apply_repo_credential              (NEW)
       - source = --repo-credential-file <path>, else
                  /etc/phantomos/argocd-repo-credential.yaml
       - validate: mode 0600, owner root:root; reject otherwise
       - validate: file is not inside a git work tree
       - kubectl apply -n argocd -f <path>
       - if --repo-credential-file given and file is not already at the
         canonical path, copy to /etc/phantomos/... 0600 root unless
         --no-persist-credential
       - poll until `argocd repo list` shows status=Successful, or fail loud
  → _gitops_render_app                         (existing)
  → kubectl apply Application CR               (existing)

argocd_users() (renamed from argocd_admin())
  → install argocd CLI (existing)
  → _argocd_set_account_password admin
  → _argocd_set_account_password operator
  → _argocd_set_account_password fleet-operator
       - bcrypt via htpasswd, patch argocd-secret stringData
         accounts.<name>.password / .passwordMtime
       - default "1984" only on first bringup; rotation requires explicit input
       - --argocd-users flag replaces --argocd-admin (with backwards-compat alias)
```

Idempotency: `kubectl apply` of the Secret and the RBAC overlays is naturally
idempotent. The encryption key file is written once and reused on subsequent
runs. Password updates are explicit per-account.

Rotation flow:

- **Routine repo credential rotation** (90d): mint a new GitHub App key,
  update `/etc/phantomos/argocd-repo-credential.yaml` on each robot
  (operator SCPs the new file), run
  `bootstrap-robot.sh --gitops-repo-credential-only`. Same code path.
- **Emergency**: revoke at GitHub first (fail-closed), then fan out the new
  file. ArgoCD sits at "auth failed" for the gap, which is acceptable —
  workloads on disk keep running, only new reconciles stall.
- **Account password rotation**: `bootstrap-robot.sh --argocd-users` re-prompts
  for the password of each account. No file involved.

`DEFAULT_REPO_URL` stays HTTPS; `phantomos-app.yaml.tpl` stays unchanged. The
match between the template's `repoURL` and the Secret's `url` field is what
binds them — ArgoCD picks the longest-prefix match.

### Migration for already-deployed robots

A short playbook (lives in [`../operations.md`](../operations.md), not this
RFC). Operator runs from a workstation with a Tailscale kubeconfig per robot
plus the credential file generated once locally:

1. Generate `argocd-repo-credential.yaml` once on the operator workstation
   (chmod `0600`).
2. For each robot:
   ```
   scp -p argocd-repo-credential.yaml \
       root@<robot>:/etc/phantomos/argocd-repo-credential.yaml
   ssh root@<robot> 'chmod 0600 /etc/phantomos/argocd-repo-credential.yaml \
                  && chown root:root /etc/phantomos/argocd-repo-credential.yaml'
   ssh root@<robot> 'bootstrap-robot.sh --gitops-repo-credential-only'
   kubectl --context=<robot> -n argocd \
       annotate application phantomos-<robot>-core \
       argocd.argoproj.io/refresh=hard --overwrite
   argocd app get phantomos-<robot>-core   # expect Synced/Healthy
   ```
3. Apply the K8s RBAC overlay (`_gitops_apply_secret_rbac`) and ArgoCD
   account RBAC overlay (`_gitops_apply_argocd_user_rbac`) the same way:
   `bootstrap-robot.sh --gitops-rbac-only`.
4. Provision the operator + fleet-operator passwords:
   `bootstrap-robot.sh --argocd-users`.
5. **Etcd encryption** can't be retrofit without a k0s restart and a one-time
   read-and-rewrite of existing Secrets (`kubectl get secrets -A -o json |
   kubectl replace -f -`). Schedule per robot as a separate maintenance
   window. Until then, threat #3 stays open only for robots that haven't
   been re-bootstrapped — track in the migration tracker.
6. Only after **every** robot reports green on step 2, flip the repo to
   private.

The `refresh=hard` annotation forces a fresh repo connection so we don't
trust a cached "public, no auth needed" state.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| One robot misses the migration step → silent reconcile failure after flip. | Pre-flip verification step in [../making-repo-private.md](../making-repo-private.md): enumerate every robot's `argocd app list` output. No flip until all green. |
| Non-root shell user reads the credential off disk. | v1: file mode `0600` `root:root`; bootstrap rejects broader perms. Same access bar as `admin.conf`. v2: closed by AWS-fetch (no file). |
| Non-root user with kubeconfig reads the K8s Secret. | `Role` + `RoleBinding` in `argocd` ns scopes `secrets` access to ArgoCD ServiceAccounts only. `admin.conf` stays root-only. Audit policy logs any `get/list secrets`. |
| Stolen robot disk → etcd dump leaks the secret. | k0s `EncryptionConfiguration` (AES-CBC, local 32-byte key at `/var/lib/k0s/pki/encryption-config.yaml` mode 0600 root). Configured before k0s start. |
| `fleet-operator` ArgoCD user deletes apps or rotates creds. | Custom `role:fleet-operator` with explicit `deny` on `applications, delete`, `clusters, *`, `repositories, create/update/delete`, `accounts, *`, `certificates, *`, `gpgkeys, *`. Casbin `deny` overrides `allow`. |
| `fleet-operator` `kubectl` user `kubectl delete ns argocd` or scales nodes. | K8s RBAC: fleet-operator kubeconfig binds `view` + a Role granting only `update/patch` on `*/scale` subresources. No `delete` on namespaces, nodes, PVs, CRDs, ClusterRoleBindings. |
| Credential file gets accidentally committed to git. | Bootstrap refuses to apply a file inside a git work tree. `.gitignore` carries the canonical path. Periodic `gitleaks` scan in CI on this repo. |
| GitHub App private key gets baked into a robot disk image. | Image pipeline forbidden from including `/etc/phantomos/argocd-repo-credential.yaml`. Bootstrap injects it at first boot, not at image build. |
| Operator's `kubectl` context config gets stale → applies to wrong robot. | Migration playbook uses `--context=<robot>` explicitly + verifies `kubectl config current-context` before each apply. |
| ArgoCD UI exposes the credential to a non-admin user. | ArgoCD redacts `password` and `githubAppPrivateKey` for non-admin callers. Verified by post-flip test logging in as `operator` and `fleet-operator`. |
| Etcd encryption key file lost / corrupted. | Bootstrap also writes `/etc/phantomos/etcd-encryption-key.bak` mode 0600 root. Operations runbook documents recovery; without the key, etcd Secrets are unreadable and must be recreated. |
| ArgoCD upgrade changes secret or RBAC schema. | Pinned ArgoCD chart version in terraform; release notes review on bump; verification includes login-as-`operator`/-`fleet-operator` regression test. |

## Verification

- Unit-ish: shellcheck-clean shim for `_gitops_apply_repo_credential`,
  `_argocd_set_account_password`, `_ensure_etcd_encryption_config` with a
  fake `kubectl` that records invocations. Assert: idempotency on re-run;
  failure on credential file with mode `0644`; failure when credential file
  is inside a git work tree; YAML structurally valid.
- File-perm check: `stat -c %a /etc/phantomos/argocd-repo-credential.yaml`
  returns `600`; `stat -c %U` returns `root`.
- K8s RBAC test:
  - `kubectl --as=system:serviceaccount:default:default -n argocd get secret
    phantomos-kos-repo` → `Forbidden`.
  - Issue a fleet-operator kubeconfig; `kubectl --kubeconfig=fleet-operator.kubeconfig
    -n argocd get secret phantomos-kos-repo` → `Forbidden`.
  - With same kubeconfig: `kubectl scale deploy/foo --replicas=2` → `Allowed`;
    `kubectl delete ns nimbus` → `Forbidden`.
- ArgoCD RBAC test:
  - `argocd login` as `operator` → `argocd app sync phantomos-<robot>-core`
    fails with permission denied; `argocd app get` succeeds.
  - `argocd login` as `fleet-operator` → `argocd app sync` succeeds;
    `argocd app delete` fails; `argocd repo add` fails;
    `argocd repo get <repo>` returns redacted password fields.
- Etcd encryption test: on the robot, `k0s etcd member-list` then
  `etcdctl get /registry/secrets/argocd/phantomos-kos-repo` → expect
  `k8s:enc:aescbc:v1:phantomos-v1:` prefix + ciphertext, **not** the PEM
  string.
- End-to-end on a test robot:
  1. Make a fresh fork of this repo and set it private.
  2. Provision a test GitHub App against the fork; render an
     `argocd-repo-credential.yaml` for it.
  3. Run `bootstrap-robot.sh --gitops --repo-credential-file ./creds.yaml`.
  4. Confirm `argocd app list` shows `Synced/Healthy` for
     `phantomos-<robot>-core`.
  5. Push a trivial manifest change to the fork; confirm reconcile picks it
     up within the configured interval.
  6. Drop a new credential file at `/etc/phantomos/argocd-repo-credential.yaml`;
     run `bootstrap-robot.sh --gitops-repo-credential-only`; confirm reconciles
     continue and old key revocation at GitHub doesn't break sync.
  7. Revoke the App install; confirm `argocd-repo-server` logs surface 401 and
     `argocd app sync` fails clearly.
- Pre-flip on the real fleet: every robot reports `Synced/Healthy` against the
  still-public repo with the new Secret in place, proving the auth path is
  exercised before privacy is required.

## Open questions

1. **GitHub App vs. PAT for v1** — depends on org-admin availability this
   week. Either way the credential file shape and the bootstrap apply path
   are the same; only the YAML keys differ.
2. **Etcd encryption key custody** — per-robot local key (proposed) vs. a
   shared key. Local is simpler and the threat being closed is "stolen disk"
   where a local-key blocks a non-root attacker anyway. Revisit if disk theft
   becomes a realistic operator threat.
3. **Should the repo credential live in `argocd` namespace only**, or also
   be replicated to a future shared namespace if other workloads need to
   pull from this repo? Defer until a second consumer appears.
4. **ApplicationSet generators** (RFC 0001 territory) will need the same
   Secret — confirm the label-based discovery is sufficient and we don't
   need an `ApplicationSet`-specific credential template.
5. **Where is `fleet-operator`'s K8s kubeconfig generated and distributed?**
   v1 proposes generating it on the robot during `bootstrap-robot.sh
   --argocd-users` and printing it for the operator to copy. Could also
   live in a per-operator file on a shared workstation. Punt to ops runbook.

## Critical files

- [../../scripts/bootstrap-robot.sh](../../scripts/bootstrap-robot.sh) — new
  `_ensure_etcd_encryption_config`, `_gitops_apply_secret_rbac`,
  `_gitops_apply_argocd_user_rbac`, `_gitops_apply_repo_credential`,
  `_argocd_set_account_password`. Rename phase 9 from `argocd_admin` to
  `argocd_users`; keep `--argocd-admin` as a compat alias.
- [../../host-config-templates/_template/phantomos-app.yaml.tpl](../../host-config-templates/_template/phantomos-app.yaml.tpl)
  — unchanged; documented here for reference.
- New: `manifests/base/argocd-secret-rbac/` — kustomize overlay with the
  K8s `Role` + `RoleBinding` scoping `secrets` access in `argocd` ns.
- New: `manifests/base/argocd-rbac/` — kustomize overlay with `argocd-cm`
  accounts patch (`operator`, `fleet-operator`) and `argocd-rbac-cm`
  `policy.csv` defining `role:fleet-operator`.
- New: `manifests/base/fleet-operator-kubectl-rbac/` — kustomize overlay
  defining the `fleet-operator` ServiceAccount, the `view` ClusterRoleBinding,
  and the cluster-wide Role granting `update/patch` on `*/scale` only.
- New: `host-config-templates/_template/argocd-repo-credential.yaml.tpl` —
  template for operators to fill in (App ID / install ID / PEM, or PAT).
  **Not** committed with values; the canonical filled file at
  `/etc/phantomos/argocd-repo-credential.yaml` is never in git.
- [../operations.md](../operations.md) — fleet migration playbook entry,
  fleet-operator kubeconfig distribution, etcd-key recovery runbook.
- [../making-repo-private.md](../making-repo-private.md) — sequencing doc
  that consumes this RFC.
