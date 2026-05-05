# System test runbook — RFC-0002 end-to-end verification

This document explains how to run `tests/system/run.sh`, which exercises the
complete RFC-0002 v1 implementation on a real or VM k0s install. The harness
covers preflight, cold bringup against a private GitOps mirror, sync
verification, manifest reconcile, ArgoCD and Kubernetes RBAC, etcd
encryption-at-rest, disk-residue grep, auth-failure mode, credential
rotation, and cleanup.

The test target is **`foundationbot/phantomos-deployer`** — the private mirror
of the implementation branch. The harness points ArgoCD at this repo (not the
production repo) to avoid polluting the real fleet.

---

## Prerequisites

### Tools

All of the following must be on `PATH` before running the harness. The
preflight phase checks each one and prints a clear message for any that are
missing.

| Tool | Minimum version | Install |
|---|---|---|
| `kubectl` | 1.27+ | k0s ships a bundled `k0s kubectl`; symlink or alias it |
| `argocd` | 2.8+ | [github.com/argoproj/argo-cd/releases](https://github.com/argoproj/argo-cd/releases) |
| `kustomize` | 5+ | `curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash` |
| `gh` | 2.28+ | `apt-get install gh` or brew |
| `curl` | any | standard |
| `htpasswd` | any | `apt-get install apache2-utils` |
| `git` | 2.25+ | standard |
| `helm` | 3.10+ | `apt-get install helm` or brew |

### GitHub CLI authentication

```bash
gh auth login
gh auth status
```

The logged-in account must have read access to
`foundationbot/phantomos-deployer`.

### Generating the credential file

The harness needs a pre-rendered ArgoCD repository Secret YAML pointed at
`foundationbot/phantomos-deployer`. It does **not** generate this file for
you.

#### Option A — GitHub App (preferred)

1. Create a GitHub App in the `foundationbot` org, scoped to
   `foundationbot/phantomos-deployer` with `Contents: Read` only.
2. Install the App on `phantomos-deployer`. Note the **App ID** and
   **Installation ID** (visible in the App's installation settings URL:
   `https://github.com/organizations/foundationbot/settings/installations/<ID>`).
3. Generate a private key from the App settings page. Download the `.pem`.
4. Render the credential file:

```bash
cat > /tmp/phantomos-test-creds.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: phantomos-kos-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/foundationbot/phantomos-deployer
  githubAppID: "<app-id>"
  githubAppInstallationID: "<install-id>"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    <paste pem contents here, indented 4 spaces>
    -----END RSA PRIVATE KEY-----
EOF
chmod 0600 /tmp/phantomos-test-creds.yaml
```

#### Option B — Fine-grained PAT (fallback)

```bash
cat > /tmp/phantomos-test-creds.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: phantomos-kos-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/foundationbot/phantomos-deployer
  username: x-access-token
  password: <fine-grained-PAT-with-Contents:Read-on-phantomos-deployer>
EOF
chmod 0600 /tmp/phantomos-test-creds.yaml
```

The PAT must have `Contents: Read` on `foundationbot/phantomos-deployer` only.
No other repositories, no write permissions.

### SSH seed (required for remote robot execution only)

If running against a robot (`TEST_ROBOT_HOST=mk11000009`), seed the robot
once before the first run:

```bash
# 1. Sync the repo to the robot (excluding .git and the system test itself).
rsync -av --exclude=.git --exclude=tests/system/ \
  . root@$TEST_ROBOT_HOST:/tmp/phantomos-deployer-test/

# 2. Copy the credential file.
scp "$ARGOCD_REPO_CREDENTIAL_FILE" \
    root@$TEST_ROBOT_HOST:/etc/phantomos/argocd-repo-credential.yaml
ssh root@$TEST_ROBOT_HOST chmod 0600 /etc/phantomos/argocd-repo-credential.yaml
```

Phase 0 (preflight) verifies both of these paths are present on the robot and
will fail with instructions if either is missing.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ARGOCD_REPO_CREDENTIAL_FILE` | `/tmp/phantomos-test-creds.yaml` | Path to credential YAML. Must be mode 0600. Required. |
| `TEST_ROBOT_HOST` | (unset) | If set, Phases 1–8 run over SSH as `root@$TEST_ROBOT_HOST` instead of locally. |
| `PHANTOMOS_TEST_NEW_CREDENTIAL_FILE` | (unset) | Path to a fresh credential file for Phase 9 (rotation drill). If unset, Phase 9 is skipped. |

---

## How to run

### Local run (dev machine / VM)

```bash
sudo ARGOCD_REPO_CREDENTIAL_FILE=/tmp/phantomos-test-creds.yaml \
  bash tests/system/run.sh
```

### Remote run (against the robot `mk11000009`)

```bash
# Seed the robot first (see "SSH seed" above).
TEST_ROBOT_HOST=mk11000009 \
  ARGOCD_REPO_CREDENTIAL_FILE=/tmp/phantomos-test-creds.yaml \
  sudo bash tests/system/run.sh
```

### Resume from a specific phase

If a run failed at Phase 4 and you've fixed the issue, restart from that
phase without re-running bringup:

```bash
sudo bash tests/system/run.sh --phase argocd-rbac
```

### Run cleanup only

```bash
sudo bash tests/system/run.sh --cleanup
```

### Collect all errors without stopping

```bash
sudo bash tests/system/run.sh --keep-going
```

---

## Phase reference

### Phase 0: Preflight

**Purpose:** Verify all preconditions before any cluster changes.

Checks:
- Running as root (k0s install requires root).
- All required tools on `PATH`.
- `gh auth status` succeeds.
- `gh` can read `foundationbot/phantomos-deployer`.
- `$ARGOCD_REPO_CREDENTIAL_FILE` exists and is mode 0600.
- Credential file `url:` field contains `phantomos-deployer` — **safety
  check** to ensure the harness is not accidentally pointed at the
  production repo.
- (SSH mode only) repo and credential file are present on the robot.

**Failure modes:**
- `required tool missing from PATH: argocd` → install the tool.
- `credential file mode is 644` → `chmod 0600 $ARGOCD_REPO_CREDENTIAL_FILE`.
- `SAFETY: credential file url does not mention phantomos-deployer` →
  regenerate the credential file against the test mirror, not the
  production repo.

---

### Phase 1: Initial bringup

**Purpose:** Run `bootstrap-robot.sh --gitops --argocd-users` with the
private test repo as the GitOps source, then verify ArgoCD is running and
the repo credential is active.

Steps:
1. Invokes `bootstrap-robot.sh` with `DEFAULT_REPO_URL` set to the
   `phantomos-deployer` URL and `--repo-credential-file` pointing at the
   credential file.
2. Waits up to 300 s for all ArgoCD pods to report `Running`.
3. `argocd login localhost:30443 --username admin --password 1984 --insecure`.
4. `argocd repo list` — expects `Successful` for `phantomos-deployer`.
5. Discovers the first `phantomos-*` Application and records its name.

**Failure modes:**
- Bootstrap exits non-zero → check bootstrap output for the specific phase
  that failed. Run `sudo bash scripts/bootstrap-robot.sh --gitops -y` manually
  and watch for the `FAIL` line.
- ArgoCD pods not Ready within 300 s → `kubectl -n argocd get pods` to
  inspect. Common cause: image pull failure for the ArgoCD Helm chart images.
- `argocd repo list` shows `ConnectionError` or missing → check
  `kubectl -n argocd logs deploy/argocd-repo-server` for auth error.

**Debug commands:**
```bash
kubectl -n argocd get pods
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
argocd repo list
kubectl -n argocd get applications
```

---

### Phase 2: Sync verification

**Purpose:** Force an `argocd app sync` and confirm the application reports
`Synced/Healthy`.

Steps:
1. `argocd app sync <name> --timeout 300`.
2. `argocd app get <name>` — grep for `Synced` and `Healthy`.

**Failure modes:**
- Sync fails with `authentication required` → credential was not applied
  correctly. Rerun Phase 1.
- Sync fails with `ComparisonError` → manifest validation issue. Check
  `kustomize build manifests/stacks/core/` locally.

**Debug commands:**
```bash
argocd app get <name>
argocd app sync <name> --dry-run
kubectl -n argocd logs job/argocd-application-controller --tail=50
```

---

### Phase 3: Manifest-change reconciliation

**Purpose:** Push a trivial manifest change to `phantomos-deployer` via the
`gh` API and confirm ArgoCD reconciles it within 3 minutes.

Steps:
1. Fetches `manifests/stacks/core/kustomization.yaml` from the `main` branch
   of `foundationbot/phantomos-deployer`.
2. Appends a timestamped comment and pushes it back via the GitHub Contents
   API.
3. Polls `argocd app get` until the revision SHA changes (max 180 s).
4. Confirms `Synced/Healthy` after reconcile.

**Failure modes:**
- `gh API PUT failed` → check `gh auth status` and PAT/App permissions
  (needs `Contents: Write` on `phantomos-deployer`).
- ArgoCD does not pick up new SHA → check ArgoCD's polling interval
  (default 3 min). Annotate manually to force:
  ```bash
  kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite
  ```

---

### Phase 4: ArgoCD account RBAC

**Purpose:** Verify `operator` (read-only) and `fleet-operator` (custom)
accounts have the intended permissions and cannot exceed them.

`operator` checks:
- `argocd app sync` → permission denied.
- `argocd app get` → success.

`fleet-operator` checks:
- `argocd app sync` → success.
- `argocd app delete` → permission denied.
- `argocd repo get <url>` → returns repo info, but no PEM or raw password
  visible in output (ArgoCD native redaction).

**Failure modes:**
- `argocd login as operator failed` → `--argocd-users` phase did not run or
  set the password incorrectly. Run:
  ```bash
  sudo bash scripts/bootstrap-robot.sh --argocd-users -y
  ```
- `operator: argocd app sync was NOT denied` → ArgoCD RBAC policy was not
  applied. Check `kubectl -n argocd get cm argocd-rbac-cm -o yaml`.
- `fleet-operator: PEM key visible` → ArgoCD version does not redact
  `githubAppPrivateKey`. Upgrade ArgoCD or pin the chart version.

---

### Phase 5: Kubernetes RBAC

**Purpose:** Verify the `fleet-operator` ServiceAccount kubeconfig has the
right K8s permissions: can view workloads and scale Deployments, but cannot
read Secrets in `argocd` or delete namespaces.

The phase generates a short-lived token for `fleet-operator` in `kube-system`
and writes a kubeconfig. Using that kubeconfig:

| Check | Expected |
|---|---|
| `kubectl get secret -n argocd phantomos-kos-repo` | `Forbidden` |
| `kubectl get pods -A` | Success |
| `kubectl scale deploy/<name> -n <ns>` | Success |
| `kubectl delete ns nimbus` | `Forbidden` |
| `kubectl get secrets -n kube-system` | `Forbidden` or empty |

**Failure modes:**
- `could not create token for fleet-operator ServiceAccount` →
  `fleet-operator-kubectl-rbac` overlay was not applied. Run:
  ```bash
  sudo bash scripts/bootstrap-robot.sh --gitops-rbac-only -y
  ```
- `fleet-operator: kubectl scale failed` → `clusterrole-scale` was not
  bound correctly. Inspect:
  ```bash
  kubectl get clusterrole fleet-operator-scale -o yaml
  kubectl get clusterrolebinding fleet-operator-view -o yaml
  ```

---

### Phase 6: Etcd encryption-at-rest

**Purpose:** Confirm the `phantomos-kos-repo` Secret is stored encrypted in
etcd (AES-CBC with key named `phantomos-v1`) and the raw PEM is not
recoverable from etcd bytes.

The phase tries multiple invocations in order until one produces output:

1. `k0s etcdctl get /registry/secrets/argocd/phantomos-kos-repo`
2. `/var/lib/k0s/bin/etcdctl --endpoints=https://127.0.0.1:2379 ...`
3. System `etcdctl` with k0s certs

If none work, the phase fails with the exact commands to run manually.

Expected: output bytes begin with `k8s:enc:aescbc:v1:phantomos-v1:` and do
**not** contain `BEGIN RSA PRIVATE KEY`.

**Failure modes:**
- Prefix absent → etcd encryption was not configured before k0s started.
  The `_ensure_etcd_encryption_config` step in `bootstrap-robot.sh` must
  run before the `cluster` phase. Check:
  ```bash
  cat /var/lib/k0s/pki/encryption-config.yaml
  k0s kubectl get apiserver -o yaml | grep encryption
  ```
- `k0s etcdctl` not found → k0s version does not bundle etcdctl as a
  subcommand. Use Option 2 (direct binary path) shown in the failure message.

---

### Phase 7: Disk-residue check

**Purpose:** `grep -r "BEGIN RSA PRIVATE KEY"` across `/etc /var /tmp /root`,
excluding `/var/lib/k0s*` (the encrypted etcd store). Only the controlled copy
at `/etc/phantomos/argocd-repo-credential.yaml` (mode 0600, root-only) is
expected.

**Failure modes:**
- PEM found at unexpected path → investigate how the PEM ended up there.
  Common causes: operator accidentally saved it to a world-readable path,
  a shell history file captured it, or a log captured a `kubectl apply -f`
  invocation that included the raw PEM.
  Resolution: `shred -u <path>` or `rm -f <path>` after inspection.

---

### Phase 8: Auth failure mode

**Purpose:** Verify that ArgoCD surfaces a clear auth error when the
credential is invalidated, and that existing pods keep running (workload
continuity during auth outage).

Steps:
1. Saves the original `phantomos-kos-repo` Secret data.
2. Patches the Secret with `password: invalidated-by-harness` and
   `githubAppPrivateKey: invalidated-by-harness`.
3. Annotates the Application with `argocd.argoproj.io/refresh=hard`.
4. Waits up to 120 s for `argocd app sync` to fail with an auth error.
5. Checks pods are still running.
6. Restores the original credential by re-applying the credential file from
   `/etc/phantomos/argocd-repo-credential.yaml`.

**Failure modes:**
- Auth error not surfaced within 120 s → ArgoCD may be using a cached
  connection. Increase wait time or force:
  ```bash
  kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite
  argocd app sync <name>
  ```
- Pods not running → existing workloads terminated during auth failure.
  This is unexpected and indicates ArgoCD self-heal pruned them — check
  the Application's `selfHeal` setting.

---

### Phase 9: Rotation drill (optional)

**Purpose:** Install a fresh credential file and verify sync resumes within
60 s using `bootstrap-robot.sh --gitops-repo-credential-only`.

Skipped if `PHANTOMOS_TEST_NEW_CREDENTIAL_FILE` is not set.

To run:
1. Mint a new GitHub App key or PAT for `phantomos-deployer`.
2. Render a new credential YAML at mode 0600.
3. Re-run with the env var set:

```bash
PHANTOMOS_TEST_NEW_CREDENTIAL_FILE=/tmp/new-creds.yaml \
  sudo bash tests/system/run.sh --phase rotation
```

**Failure modes:**
- `could not scp new credential` → SSH connectivity issue or `/etc/phantomos/`
  does not exist on the robot. Create the directory:
  ```bash
  ssh root@$TEST_ROBOT_HOST mkdir -p /etc/phantomos
  ```
- Sync did not resume within 60 s → the new credential may be invalid (wrong
  App ID, expired PAT, wrong PEM). Verify with `argocd repo list` after
  applying.

---

### Phase 10: Migration drill

Always skipped in the single-machine harness. Requires a second robot.

Manual procedure (two-robot):
1. Configure a second robot's `host-config.yaml` with the same
   `phantomos-deployer` `targetRevision`.
2. SCP the credential file to the second robot.
3. Run `bootstrap-robot.sh` on the second robot.
4. `argocd app list` on both robots should show `Synced/Healthy`.

---

### Phase 11: Cleanup

**Purpose:** Tear down the test cluster and remove test artifacts.

Steps:
1. `bootstrap-robot.sh --reset -y` — stops k0s, backs up kubeconfig and
   terraform state.
2. Removes `/tmp/phantomos-test-creds.yaml` (only if it matches the default
   path — custom paths are left alone).
3. Removes `/etc/phantomos/argocd-repo-credential.yaml`.
4. (SSH mode) removes `/tmp/fleet-operator-test.kubeconfig` from the robot.

Run manually: `sudo bash tests/system/run.sh --cleanup`

---

## Cleanup instructions (manual)

If the harness crashes mid-run and `--cleanup` doesn't reach the cleanup
phase:

```bash
# Stop k0s
sudo k0s stop
sudo k0s reset

# Remove credential file (if it's the test one)
sudo rm -f /tmp/phantomos-test-creds.yaml

# Remove robot-side credential
sudo rm -f /etc/phantomos/argocd-repo-credential.yaml

# On the robot (SSH mode)
ssh root@mk11000009 'k0s stop; k0s reset; rm -f /etc/phantomos/argocd-repo-credential.yaml'
```

---

## Quick reference: kubectl commands for debugging

```bash
# All ArgoCD pods
kubectl -n argocd get pods

# ArgoCD application status
kubectl -n argocd get applications

# Repo server logs (auth failures appear here)
kubectl -n argocd logs deploy/argocd-repo-server --tail=100

# Application controller logs
kubectl -n argocd logs deploy/argocd-application-controller --tail=100

# Force hard refresh
kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite

# Inspect the repo credential Secret (admin only)
kubectl -n argocd get secret phantomos-kos-repo -o yaml

# Check ArgoCD RBAC policy
kubectl -n argocd get cm argocd-rbac-cm -o yaml

# Check ArgoCD account config
kubectl -n argocd get cm argocd-cm -o yaml

# Check etcd encryption config
sudo cat /var/lib/k0s/pki/encryption-config.yaml

# Check fleet-operator RBAC
kubectl get clusterrolebinding fleet-operator-view -o yaml
kubectl get clusterrole fleet-operator-scale -o yaml
```
