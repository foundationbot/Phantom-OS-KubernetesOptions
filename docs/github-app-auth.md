# GitHub App auth for ArgoCD on the Phantom-OS fleet

Plan for moving the `Phantom-OS-KubernetesOptions` repo from public to private without losing ArgoCD's ability to fetch manifests on every robot.

## Why a GitHub App (vs deploy key / PAT)

- **Fleet-friendly.** One App, installed once on the org, usable by every robot. Deploy keys are per-repo-per-cluster; PATs are tied to a human account.
- **Short-lived tokens.** ArgoCD mints fresh 1-hour installation tokens from the App's private key. The long-term secret on each robot is just the private key — token theft has a 1-hour blast radius.
- **Auditable.** GitHub logs each token mint and each git operation against an identifiable App, not "siddhant's PAT".
- **Native ArgoCD support.** ArgoCD has built-in GitHub App handling — no sidecar / external token-rotator needed.

## Setup

### 1. Create the App

GitHub → org `foundationbot` settings → Developer settings → GitHub Apps → **New GitHub App**.

- **Name**: `phantom-fleet-argocd`
- **Homepage URL**: anything (required field, not used)
- **Webhook**: uncheck "Active"
- **Permissions** → Repository:
  - Contents: **Read-only**
  - Metadata: Read-only (auto-set)
- **Where can this be installed**: *Only on this account*
- Save → note the **App ID**.
- Click **Generate a private key** → downloads `.pem`. Stash in 1Password.

### 2. Install on the repo

On the App page → **Install App** → `foundationbot` → *Only select repositories* → pick `Phantom-OS-KubernetesOptions`.

The install URL becomes `.../settings/installations/<id>` — that `<id>` is the **Installation ID**.

You now have: **App ID**, **Installation ID**, **Private Key (PEM)**.

### 3. Add the credentials to each robot's ArgoCD

For each robot, create a Repository secret in the `argocd` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: phantom-os-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/foundationbot/Phantom-OS-KubernetesOptions
  githubAppID: "<APP_ID>"
  githubAppInstallationID: "<INSTALLATION_ID>"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    <PEM contents>
    -----END RSA PRIVATE KEY-----
```

Apply per cluster:

```bash
KUBECONFIG=~/.kube/mk09-config   kubectl apply -f phantom-os-repo.yaml
KUBECONFIG=~/.kube/ak-007-config kubectl apply -f phantom-os-repo.yaml
```

**Do not commit this file to git** — it contains the private key. Keep it in 1Password and re-render per robot, or use `sealed-secrets` / `sops` if you want it in git.

### 4. Verify against the still-public repo

Before flipping visibility, prove the App works end-to-end:

```bash
# Force ArgoCD to refresh through the new credential path
KUBECONFIG=~/.kube/mk09-config kubectl -n argocd annotate application phantomos-mk09 \
  argocd.argoproj.io/refresh=hard --overwrite

# Check sync status
KUBECONFIG=~/.kube/mk09-config kubectl -n argocd get application phantomos-mk09
```

Application should remain `Synced + Healthy`. If it errors, fix auth before going further.

### 5. Update Terraform + `bootstrap-robot.sh`

These also clone the repo today.

- **Terraform**: pass App credentials via env / tfvars; reference them in whichever data source clones the repo.
- **`scripts/bootstrap-robot.sh`**: replace plain `git clone https://github.com/...` with a token-bearing URL. Easiest pattern: have the script mint a 1-hour installation token (small Python helper using App ID + private key + installation ID) and clone with `https://x-access-token:<token>@github.com/foundationbot/...`.

### 6. Flip the repo to private

GitHub → repo Settings → General → Danger Zone → **Change visibility → Private**.

Watch every cluster for ~10 minutes:

```bash
for cfg in mk09-config ak-007-config; do
  echo "=== $cfg ==="
  KUBECONFIG=~/.kube/$cfg kubectl -n argocd get applications
done
```

Anything not `Synced + Healthy` is a robot whose auth didn't propagate — investigate that one robot, the rest are fine.

## Rollback

If something goes wrong, flip the repo back to public. Robots resume working immediately. The visibility flag is safely reversible — there's no point of no return in this migration.

## Order of operations summary

1. Create the App + private key.
2. Install on the repo.
3. Apply the Repository secret to **every** robot's `argocd` namespace.
4. Verify each robot's ArgoCD can sync via the App (still-public repo).
5. Update Terraform + `bootstrap-robot.sh` to use App-minted tokens.
6. Flip the repo to private.
7. Watch sync status on every robot.

Step 3 is the gate: as long as that works on every robot before step 6, there's no outage window.
