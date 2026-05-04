# Private-Repo ArgoCD Auth — Implementation Plan (v1, file-credential)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make this repo safe to flip to private — every robot's ArgoCD authenticates to the private GitOps source via a root-only credential file, K8s + ArgoCD RBAC scopes blast radius, and etcd encrypts Secrets at rest. No regressions on existing bringup.

**Architecture:** Three layers, all in v1: (1) credential file at `/etc/phantomos/argocd-repo-credential.yaml` (mode 0600, root) applied by `bootstrap-robot.sh` as a `repository`-typed K8s `Secret`; (2) RBAC overlays under `manifests/base/` — K8s `Role` locking `secrets` reads in `argocd` ns to ArgoCD's own ServiceAccounts, plus `argocd-cm` accounts + `argocd-rbac-cm` policy.csv defining `operator` (readonly) and `fleet-operator` (sync + scale, no delete, no creds-read), plus a separate K8s `view + */scale` binding for fleet-operator's kubeconfig; (3) k0s `EncryptionConfiguration` with a per-robot AES-CBC key, configured before k0s start. AWS-source for the credential is deferred to v2.

**Tech Stack:** Bash 5 (existing `scripts/bootstrap-robot.sh`), kustomize-style YAML overlays, kubectl, k0s, ArgoCD Helm chart (already installed via terraform), htpasswd (bcrypt), bats-core (new — for shell tests).

**Reference docs:**
- [`docs/rfcs/0002-private-repo-argocd-auth.md`](../../rfcs/0002-private-repo-argocd-auth.md) — design.
- [`docs/making-repo-private.md`](../../making-repo-private.md) — sequencing.

---

## File Structure

**New files (created by this plan):**

| Path | Responsibility |
|---|---|
| `manifests/base/argocd-secret-rbac/role.yaml` | K8s `Role` granting `get/list/watch secrets` in `argocd` ns. |
| `manifests/base/argocd-secret-rbac/rolebinding.yaml` | `RoleBinding` from the Role to ArgoCD's own ServiceAccounts only. |
| `manifests/base/argocd-secret-rbac/kustomization.yaml` | Bundles the two above. |
| `manifests/base/argocd-rbac/argocd-cm-patch.yaml` | Strategic-merge patch on `argocd-cm` adding `accounts.operator` + `accounts.fleet-operator`. |
| `manifests/base/argocd-rbac/argocd-rbac-cm-patch.yaml` | Strategic-merge patch on `argocd-rbac-cm` defining `policy.csv` with `role:fleet-operator`. |
| `manifests/base/argocd-rbac/kustomization.yaml` | Bundles the two patches. |
| `manifests/base/fleet-operator-kubectl-rbac/serviceaccount.yaml` | `fleet-operator` ServiceAccount in `kube-system`. |
| `manifests/base/fleet-operator-kubectl-rbac/clusterrolebinding-view.yaml` | Binds the SA to built-in `view` ClusterRole (read everything except secrets). |
| `manifests/base/fleet-operator-kubectl-rbac/clusterrole-scale.yaml` | Custom ClusterRole granting `update,patch` on `*/scale` only. |
| `manifests/base/fleet-operator-kubectl-rbac/clusterrolebinding-scale.yaml` | Binds the scale ClusterRole to the SA. |
| `manifests/base/fleet-operator-kubectl-rbac/kustomization.yaml` | Bundles the four above. |
| `host-config-templates/_template/argocd-repo-credential.yaml.tpl` | Template the operator fills with App ID / install ID / PEM (or PAT). Carries placeholders, never real values. |
| `scripts/lib/argocd_users.sh` | Sourceable lib with `_argocd_set_account_password`, isolated from `bootstrap-robot.sh` so it's unit-testable. |
| `scripts/lib/repo_credential.sh` | Sourceable lib with `_validate_repo_credential_file`, `_apply_repo_credential`. |
| `scripts/lib/etcd_encryption.sh` | Sourceable lib with `_ensure_etcd_encryption_config` (key gen, file write, k0s wiring). |
| `tests/bash/Makefile` | Single entry: `make test` runs all bats suites. |
| `tests/bash/helpers/load.bash` | Common bats helper — sets `PATH` to stub dir, loads SUT lib. |
| `tests/bash/stubs/kubectl` | Records args to `$STUB_LOG_KUBECTL`; exits 0 unless `$STUB_KUBECTL_FAIL=1`. |
| `tests/bash/stubs/htpasswd` | Emits a fixed bcrypt-shaped string for deterministic password tests. |
| `tests/bash/stubs/k0s` | No-op stub. |
| `tests/bash/stubs/argocd` | Records args; emits canned responses for `repo list` etc. |
| `tests/bash/argocd_users.bats` | Tests for `_argocd_set_account_password`. |
| `tests/bash/repo_credential.bats` | Tests for `_validate_repo_credential_file`, `_apply_repo_credential`. |
| `tests/bash/etcd_encryption.bats` | Tests for `_ensure_etcd_encryption_config`. |
| `tests/bash/manifest_overlays.bats` | Validates overlay YAML compiles via `kustomize build` and contains expected fields. |

**Modified files:**

| Path | What changes |
|---|---|
| [`scripts/bootstrap-robot.sh`](../../../scripts/bootstrap-robot.sh) | Source the three new libs; rename `argocd_admin()` → `argocd_users()`; add new gitops sub-steps `_gitops_apply_secret_rbac`, `_gitops_apply_argocd_user_rbac`, `_gitops_apply_repo_credential`; add `_ensure_etcd_encryption_config` to `deps()`; add CLI flags `--argocd-users`, `--repo-credential-file`, `--gitops-repo-credential-only`, `--gitops-rbac-only`; add `BOOTSTRAP_LIB_ONLY` source-guard at the bottom. |
| [`docs/operations.md`](../../operations.md) | New sections: fleet-operator kubeconfig issuance, etcd-key recovery, credential rotation. |
| `.gitignore` (root) | Add `argocd-repo-credential.yaml` (any path) to keep filled credentials from being committed. |

**Phasing:** Tasks are ordered so each one delivers a green test suite. Manifests come first (no script churn), then library extraction with unit tests, then `bootstrap-robot.sh` integration, then docs, then a manual end-to-end task on a dev robot.

---

## Task 1: Bats test harness scaffolding

**Files:**
- Create: `tests/bash/Makefile`
- Create: `tests/bash/helpers/load.bash`
- Create: `tests/bash/stubs/kubectl`
- Create: `tests/bash/stubs/htpasswd`
- Create: `tests/bash/stubs/k0s`
- Create: `tests/bash/stubs/argocd`
- Create: `tests/bash/smoke.bats`

- [ ] **Step 1: Confirm bats-core is available**

Run: `which bats || sudo apt install -y bats`
Expected: prints a path like `/usr/bin/bats`. Bats version 1.x or newer.

- [ ] **Step 2: Write `tests/bash/Makefile`**

```makefile
# tests/bash/Makefile — single entry-point for shell tests.
# Run from repo root: make -C tests/bash test
.PHONY: test
test:
	@bats $(CURDIR)/*.bats
```

- [ ] **Step 3: Write `tests/bash/helpers/load.bash`**

```bash
# Common bats helpers. Sourced via `load 'helpers/load'` from each .bats file.
# Puts the stub dir on PATH so kubectl/htpasswd/k0s/argocd resolve to stubs.
# Each test gets a fresh tmp BATS_TMPDIR for log files.

_load_repo_root() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
}

_install_stubs() {
  STUBS_DIR="${BATS_TEST_DIRNAME}/stubs"
  PATH="${STUBS_DIR}:${PATH}"
  export PATH
  STUB_LOG_DIR="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "$STUB_LOG_DIR"
  export STUB_LOG_DIR
  export STUB_LOG_KUBECTL="${STUB_LOG_DIR}/kubectl.log"
  export STUB_LOG_ARGOCD="${STUB_LOG_DIR}/argocd.log"
  export STUB_LOG_HTPASSWD="${STUB_LOG_DIR}/htpasswd.log"
}

setup_common() {
  _load_repo_root
  _install_stubs
}
```

- [ ] **Step 4: Write `tests/bash/stubs/kubectl`**

```bash
#!/usr/bin/env bash
# Stub kubectl: appends args to $STUB_LOG_KUBECTL, reads optional stdin to
# a sibling .stdin file, exits 0 unless $STUB_KUBECTL_FAIL=1.
set -euo pipefail
log="${STUB_LOG_KUBECTL:?STUB_LOG_KUBECTL not set}"
printf '%s\n' "$*" >> "$log"
if [ ! -t 0 ]; then
  cat >> "${log}.stdin" || true
fi
if [ "${STUB_KUBECTL_FAIL:-0}" = 1 ]; then
  echo "stub-kubectl: forced failure" >&2
  exit 1
fi
# A few canned responses used by bootstrap probes:
case "$*" in
  *"-n argocd get secret argocd-secret"*) echo 'argocd-secret 1';;
  *"get secret argocd-initial-admin-secret"*) exit 1;;  # not present
  *) :;;
esac
exit 0
```

- [ ] **Step 5: Mark stubs executable**

Run: `chmod +x tests/bash/stubs/kubectl`
Expected: no output, file is now `-rwxr-xr-x`.

- [ ] **Step 6: Write `tests/bash/stubs/htpasswd`**

```bash
#!/usr/bin/env bash
# Stub htpasswd: emits a deterministic bcrypt-shaped string and logs args.
# Real htpasswd output looks like ":$2y$10$..."; we mimic shape, not crypto.
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG_HTPASSWD:?}"
printf ':$2y$10$0000000000000000000000.aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
```

`chmod +x tests/bash/stubs/htpasswd`.

- [ ] **Step 7: Write `tests/bash/stubs/k0s` and `tests/bash/stubs/argocd`**

```bash
# tests/bash/stubs/k0s
#!/usr/bin/env bash
set -euo pipefail
printf 'k0s %s\n' "$*" >> "${STUB_LOG_DIR}/k0s.log"
exit 0
```

```bash
# tests/bash/stubs/argocd
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG_ARGOCD:?}"
case "$*" in
  "version --client"*|"version --client --short"*) echo 'argocd: v2.10.0';;
  "repo list"*) printf 'TYPE  NAME  REPO  STATUS\ngit   kos   https://github.com/foundationbot/Phantom-OS-KubernetesOptions  Successful\n';;
  *) :;;
esac
exit 0
```

`chmod +x tests/bash/stubs/k0s tests/bash/stubs/argocd`.

- [ ] **Step 8: Write `tests/bash/smoke.bats` (verifies the harness itself)**

```bash
# tests/bash/smoke.bats
load 'helpers/load'
setup() { setup_common; }

@test "stub kubectl logs args and exits 0" {
  run kubectl get pods -n default
  [ "$status" -eq 0 ]
  grep -q 'get pods -n default' "$STUB_LOG_KUBECTL"
}

@test "stub kubectl honors STUB_KUBECTL_FAIL" {
  STUB_KUBECTL_FAIL=1 run kubectl get pods
  [ "$status" -ne 0 ]
}

@test "stub htpasswd emits bcrypt-shaped string" {
  run htpasswd -nbBC 10 "" "hunter2"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^:\$2y\$10\$ ]]
}
```

- [ ] **Step 9: Run smoke tests — expect PASS**

Run: `make -C tests/bash test`
Expected: `3 tests, 0 failures`.

- [ ] **Step 10: Commit**

```bash
git add tests/bash/Makefile tests/bash/helpers tests/bash/stubs tests/bash/smoke.bats
git commit -m "test: add bats-core harness with kubectl/htpasswd/k0s/argocd stubs"
```

---

## Task 2: K8s secret-RBAC manifest overlay

**Files:**
- Create: `manifests/base/argocd-secret-rbac/role.yaml`
- Create: `manifests/base/argocd-secret-rbac/rolebinding.yaml`
- Create: `manifests/base/argocd-secret-rbac/kustomization.yaml`
- Create: `tests/bash/manifest_overlays.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/bash/manifest_overlays.bats
load 'helpers/load'
setup() { setup_common; }

@test "argocd-secret-rbac kustomize build emits Role and RoleBinding" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-secret-rbac")"
  echo "$out" | grep -q 'kind: Role'
  echo "$out" | grep -q 'kind: RoleBinding'
  echo "$out" | grep -q 'namespace: argocd'
}

@test "argocd-secret-rbac Role grants only get/list/watch on secrets" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-secret-rbac")"
  echo "$out" | grep -q 'resources:'
  echo "$out" | grep -q 'secrets'
  ! echo "$out" | grep -E 'verbs:.*\b(create|update|patch|delete|deletecollection)\b'
}

@test "argocd-secret-rbac RoleBinding subjects are ServiceAccounts only" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-secret-rbac")"
  echo "$out" | awk '/^subjects:/,/^---/' | grep -q 'kind: ServiceAccount'
  ! echo "$out" | awk '/^subjects:/,/^---/' | grep -qE 'kind: (User|Group)'
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make -C tests/bash test`
Expected: FAIL — `manifests/base/argocd-secret-rbac` doesn't exist yet.

- [ ] **Step 3: Write `manifests/base/argocd-secret-rbac/role.yaml`**

```yaml
# Read access to Secrets in the argocd namespace, scoped to ArgoCD's own
# components. Bound by rolebinding.yaml. No human is bound to this Role.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-secret-reader
  namespace: argocd
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
```

- [ ] **Step 4: Write `manifests/base/argocd-secret-rbac/rolebinding.yaml`**

```yaml
# Bind argocd-secret-reader to the ArgoCD ServiceAccounts that legitimately
# need it. Names match the argo-cd Helm chart defaults; verify with
# `kubectl -n argocd get sa` after install.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-secret-reader
  namespace: argocd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-secret-reader
subjects:
  - kind: ServiceAccount
    name: argocd-server
    namespace: argocd
  - kind: ServiceAccount
    name: argocd-repo-server
    namespace: argocd
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: argocd
  - kind: ServiceAccount
    name: argocd-applicationset-controller
    namespace: argocd
  - kind: ServiceAccount
    name: argocd-notifications-controller
    namespace: argocd
```

- [ ] **Step 5: Write `manifests/base/argocd-secret-rbac/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - role.yaml
  - rolebinding.yaml
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: smoke 3/3 + manifest_overlays 3/3 = 6 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add manifests/base/argocd-secret-rbac/ tests/bash/manifest_overlays.bats
git commit -m "manifests: add argocd-secret-rbac overlay for K8s secret lockdown"
```

---

## Task 3: ArgoCD account RBAC overlay (operator + fleet-operator)

**Files:**
- Create: `manifests/base/argocd-rbac/argocd-cm-patch.yaml`
- Create: `manifests/base/argocd-rbac/argocd-rbac-cm-patch.yaml`
- Create: `manifests/base/argocd-rbac/kustomization.yaml`
- Modify: `tests/bash/manifest_overlays.bats`

- [ ] **Step 1: Append failing tests to `tests/bash/manifest_overlays.bats`**

```bash
@test "argocd-rbac overlay declares operator and fleet-operator accounts" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-rbac")"
  echo "$out" | grep -q 'accounts.operator: login'
  echo "$out" | grep -q 'accounts.fleet-operator: login'
  echo "$out" | grep -q 'accounts.operator.enabled: "true"'
  echo "$out" | grep -q 'accounts.fleet-operator.enabled: "true"'
}

@test "argocd-rbac policy.csv binds operator to readonly and fleet-operator to custom role" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-rbac")"
  echo "$out" | grep -qE 'g, operator,\s+role:readonly'
  echo "$out" | grep -qE 'g, fleet-operator,\s+role:fleet-operator'
}

@test "role:fleet-operator allows sync/action and denies destructive ops" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-rbac")"
  # allows
  echo "$out" | grep -qE 'p, role:fleet-operator, applications, sync,\s+\*/\*, allow'
  echo "$out" | grep -qE 'p, role:fleet-operator, applications, action/\*,\s+\*/\*, allow'
  # denies (Casbin: deny overrides allow)
  echo "$out" | grep -qE 'p, role:fleet-operator, applications, delete,\s+\*/\*, deny'
  echo "$out" | grep -qE 'p, role:fleet-operator, clusters, \*,\s+\*, deny'
  echo "$out" | grep -qE 'p, role:fleet-operator, repositories, (create|update|delete),\s+\*, deny'
  echo "$out" | grep -qE 'p, role:fleet-operator, accounts, \*,\s+\*, deny'
  echo "$out" | grep -qE 'p, role:fleet-operator, exec, create,\s+\*/\*, deny'
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `make -C tests/bash test`
Expected: the three new tests fail (overlay doesn't exist yet); smoke + Task 2 still pass.

- [ ] **Step 3: Write `manifests/base/argocd-rbac/argocd-cm-patch.yaml`**

```yaml
# Strategic-merge patch on the argocd-cm ConfigMap installed by the Helm
# chart. Adds two non-admin accounts. Passwords are set out-of-band by
# scripts/bootstrap-robot.sh (see argocd_users phase) — they are NOT
# stored in this manifest.
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  accounts.operator: login
  accounts.operator.enabled: "true"
  accounts.fleet-operator: login
  accounts.fleet-operator.enabled: "true"
```

- [ ] **Step 4: Write `manifests/base/argocd-rbac/argocd-rbac-cm-patch.yaml`**

```yaml
# Strategic-merge patch on argocd-rbac-cm. Defines role:fleet-operator and
# binds operator → role:readonly, fleet-operator → role:fleet-operator.
# Casbin: deny rules override allow rules, so the deny block is what makes
# the negative permissions stick.
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: ""
  policy.csv: |
    # role:fleet-operator — sync apps, run resource actions (scale, restart),
    # override sync, read repos/projects/logs. No delete, no creds-write,
    # no cluster ops, no kubectl-exec.
    p, role:fleet-operator, applications, get,        */*, allow
    p, role:fleet-operator, applications, sync,       */*, allow
    p, role:fleet-operator, applications, action/*,   */*, allow
    p, role:fleet-operator, applications, override,   */*, allow
    p, role:fleet-operator, repositories, get,        *,   allow
    p, role:fleet-operator, projects,     get,        *,   allow
    p, role:fleet-operator, logs,         get,        */*, allow

    # explicit denies (deny overrides allow in Casbin)
    p, role:fleet-operator, exec,         create,     */*, deny
    p, role:fleet-operator, applications, delete,     */*, deny
    p, role:fleet-operator, clusters,     *,          *,   deny
    p, role:fleet-operator, repositories, create,     *,   deny
    p, role:fleet-operator, repositories, update,     *,   deny
    p, role:fleet-operator, repositories, delete,     *,   deny
    p, role:fleet-operator, accounts,     *,          *,   deny
    p, role:fleet-operator, certificates, *,          *,   deny
    p, role:fleet-operator, gpgkeys,      *,          *,   deny

    # bindings
    g, operator,        role:readonly
    g, fleet-operator,  role:fleet-operator
```

- [ ] **Step 5: Write `manifests/base/argocd-rbac/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - argocd-cm-patch.yaml
  - argocd-rbac-cm-patch.yaml
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 9 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add manifests/base/argocd-rbac/ tests/bash/manifest_overlays.bats
git commit -m "manifests: add argocd-rbac overlay for operator and fleet-operator accounts"
```

---

## Task 4: fleet-operator kubectl-RBAC overlay

**Files:**
- Create: `manifests/base/fleet-operator-kubectl-rbac/serviceaccount.yaml`
- Create: `manifests/base/fleet-operator-kubectl-rbac/clusterrolebinding-view.yaml`
- Create: `manifests/base/fleet-operator-kubectl-rbac/clusterrole-scale.yaml`
- Create: `manifests/base/fleet-operator-kubectl-rbac/clusterrolebinding-scale.yaml`
- Create: `manifests/base/fleet-operator-kubectl-rbac/kustomization.yaml`
- Modify: `tests/bash/manifest_overlays.bats`

- [ ] **Step 1: Append failing tests to `tests/bash/manifest_overlays.bats`**

```bash
@test "fleet-operator-kubectl-rbac overlay defines SA, view binding, scale ClusterRole" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/fleet-operator-kubectl-rbac")"
  echo "$out" | grep -q 'kind: ServiceAccount'
  echo "$out" | grep -q 'name: fleet-operator'
  # bound to built-in `view` ClusterRole
  echo "$out" | grep -qE 'name: view'
  # scale ClusterRole
  echo "$out" | grep -q 'kind: ClusterRole'
  echo "$out" | grep -q 'fleet-operator-scale'
}

@test "fleet-operator scale ClusterRole permits update/patch on */scale only" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/fleet-operator-kubectl-rbac")"
  # rule names *only* the scale subresources
  echo "$out" | grep -qE 'deployments/scale'
  echo "$out" | grep -qE 'statefulsets/scale'
  echo "$out" | grep -qE 'replicasets/scale'
  # verbs are exactly update,patch — no get/list/delete on scale
  ! echo "$out" | awk '/fleet-operator-scale/,/^---/' | grep -qE 'verbs:.*\b(create|delete|deletecollection)\b'
  # explicit absence of secret read in any rule of this overlay
  ! echo "$out" | grep -qE 'resources:.*\bsecrets\b'
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `make -C tests/bash test`
Expected: 2 new failures (overlay missing).

- [ ] **Step 3: Write `manifests/base/fleet-operator-kubectl-rbac/serviceaccount.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fleet-operator
  namespace: kube-system
```

- [ ] **Step 4: Write `manifests/base/fleet-operator-kubectl-rbac/clusterrolebinding-view.yaml`**

```yaml
# Built-in `view` ClusterRole: read everything *except* secrets and tokens.
# That's exactly what fleet-operator needs as a base.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fleet-operator-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: fleet-operator
    namespace: kube-system
```

- [ ] **Step 5: Write `manifests/base/fleet-operator-kubectl-rbac/clusterrole-scale.yaml`**

```yaml
# fleet-operator can scale workloads up/down via `kubectl scale` or
# `kubectl patch`. No other mutations: no delete, no exec, no create.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fleet-operator-scale
rules:
  - apiGroups: ["apps"]
    resources:
      - deployments/scale
      - statefulsets/scale
      - replicasets/scale
    verbs: ["update", "patch"]
```

- [ ] **Step 6: Write `manifests/base/fleet-operator-kubectl-rbac/clusterrolebinding-scale.yaml`**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fleet-operator-scale
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fleet-operator-scale
subjects:
  - kind: ServiceAccount
    name: fleet-operator
    namespace: kube-system
```

- [ ] **Step 7: Write `manifests/base/fleet-operator-kubectl-rbac/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - serviceaccount.yaml
  - clusterrolebinding-view.yaml
  - clusterrole-scale.yaml
  - clusterrolebinding-scale.yaml
```

- [ ] **Step 8: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 11 tests, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add manifests/base/fleet-operator-kubectl-rbac/ tests/bash/manifest_overlays.bats
git commit -m "manifests: add fleet-operator kubectl RBAC (view + scale, no secrets, no delete)"
```

---

## Task 5: Make `bootstrap-robot.sh` sourceable for tests

**Why:** the current script ends with raw phase calls (see [`scripts/bootstrap-robot.sh`](../../../scripts/bootstrap-robot.sh) bottom). Sourcing it in tests would execute every phase. We add a single guard so tests can `BOOTSTRAP_LIB_ONLY=1 source scripts/bootstrap-robot.sh` to load functions without running.

**Files:**
- Modify: `scripts/bootstrap-robot.sh` (final block)
- Create: `tests/bash/sourceable.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/bash/sourceable.bats
load 'helpers/load'
setup() { setup_common; }

@test "BOOTSTRAP_LIB_ONLY=1 source loads functions without running phases" {
  BOOTSTRAP_LIB_ONLY=1 run bash -c \
    "source '$REPO_ROOT/scripts/bootstrap-robot.sh' && declare -F argocd_admin"
  [ "$status" -eq 0 ]
  [[ "$output" =~ argocd_admin ]]
}

@test "default invocation (no LIB_ONLY) still calls phases" {
  # Use --help so it exits cleanly without doing real work.
  run bash "$REPO_ROOT/scripts/bootstrap-robot.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "phase 1: preflight" ]] || [[ "$output" =~ "usage" ]]
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `make -C tests/bash test`
Expected: first test fails (sourcing runs main); second may or may not depending on usage output.

- [ ] **Step 3: Patch the bottom of `scripts/bootstrap-robot.sh`**

Locate the block beginning with `deps               ; guard` (currently near the end, see [bootstrap-robot.sh](../../../scripts/bootstrap-robot.sh) bottom). Wrap it:

```bash
# (existing) — final phase invocations, now gated for sourceability.
if [ "${BOOTSTRAP_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

deps               ; guard
cluster            ; guard
host_config        ; guard
seed_pull_secrets  ; guard
operator_ui_config ; guard
install_dma_ethercat ; guard
gitops             ; guard
argocd_admin       ; guard
image_overrides    ; guard
deployments_phase  ; guard
setup_positronic   ; guard
validate

summary
exit "$FAIL"
```

The `return 0 2>/dev/null || exit 0` works whether the script is sourced (`return`) or executed (`exit`).

- [ ] **Step 4: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 13 tests, 0 failures.

- [ ] **Step 5: Run the script normally to verify no regression**

Run: `bash scripts/bootstrap-robot.sh --help 2>&1 | head -5`
Expected: usage banner, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap-robot.sh tests/bash/sourceable.bats
git commit -m "bootstrap: gate phase invocations behind BOOTSTRAP_LIB_ONLY for unit tests"
```

---

## Task 6: Extract `_argocd_set_account_password` into `scripts/lib/argocd_users.sh`

**Why:** The current [`argocd_admin()`](../../../scripts/bootstrap-robot.sh#L2057) has the bcrypt + patch logic hardwired to `admin`. We extract a function that takes an account name, then call it three times (admin/operator/fleet-operator).

**Files:**
- Create: `scripts/lib/argocd_users.sh`
- Create: `tests/bash/argocd_users.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/bash/argocd_users.bats
load 'helpers/load'
setup() {
  setup_common
  source "$REPO_ROOT/scripts/lib/argocd_users.sh" 2>/dev/null || true
  # The functions need a tiny shim from bootstrap-robot.sh's logging.
  pass()  { echo "PASS: $*" >> "$BATS_TEST_TMPDIR/log"; }
  fail()  { echo "FAIL: $*" >> "$BATS_TEST_TMPDIR/log"; FAIL=$((FAIL+1)); }
  info()  { echo "INFO: $*" >> "$BATS_TEST_TMPDIR/log"; }
  KUBECTL=(kubectl)
  FAIL=0
}

@test "_argocd_set_account_password rejects empty account name" {
  run _argocd_set_account_password "" "hunter2"
  [ "$status" -ne 0 ]
}

@test "_argocd_set_account_password admin patches admin.password key" {
  _argocd_set_account_password admin "hunter2"
  grep -q 'patch secret argocd-secret' "$STUB_LOG_KUBECTL"
  grep -q '"admin.password"' "${STUB_LOG_KUBECTL}.stdin" \
    || grep -q 'admin.password' "$STUB_LOG_KUBECTL"
}

@test "_argocd_set_account_password operator patches accounts.operator.password key" {
  _argocd_set_account_password operator "hunter2"
  grep -q 'accounts.operator.password' "$STUB_LOG_KUBECTL" \
    || grep -q 'accounts.operator.password' "${STUB_LOG_KUBECTL}.stdin"
}

@test "_argocd_set_account_password fleet-operator patches accounts.fleet-operator.password" {
  _argocd_set_account_password fleet-operator "hunter2"
  grep -q 'accounts.fleet-operator.password' "$STUB_LOG_KUBECTL" \
    || grep -q 'accounts.fleet-operator.password' "${STUB_LOG_KUBECTL}.stdin"
}

@test "_argocd_set_account_password fails loudly if argocd-secret missing" {
  STUB_KUBECTL_FAIL=1 run _argocd_set_account_password operator "hunter2"
  [ "$FAIL" -gt 0 ] || [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run — expect FAIL** (`scripts/lib/argocd_users.sh` doesn't exist)

Run: `make -C tests/bash test`

- [ ] **Step 3: Write `scripts/lib/argocd_users.sh`**

```bash
# scripts/lib/argocd_users.sh — set ArgoCD per-account passwords by patching
# argocd-secret. Sourced by bootstrap-robot.sh; unit-tested via bats with a
# stubbed kubectl/htpasswd. Depends on bash-level helpers (pass/fail/info)
# and KUBECTL[] from the caller.

# _argocd_set_account_password <account> <plaintext>
#   Bcrypts the plaintext via htpasswd and patches argocd-secret with the
#   per-account keys (admin uses the legacy unprefixed keys; everyone else
#   uses accounts.<name>.password / .passwordMtime).
_argocd_set_account_password() {
  local account="${1:-}" pw="${2:-}"
  if [ -z "$account" ]; then
    fail "_argocd_set_account_password: account name required"
    return 2
  fi
  if [ -z "$pw" ]; then
    fail "_argocd_set_account_password: password required for '$account'"
    return 2
  fi

  if ! command -v htpasswd >/dev/null 2>&1; then
    info "installing apache2-utils (for htpasswd)"
    apt-get install -y apache2-utils >/dev/null 2>&1 || true
  fi
  if ! command -v htpasswd >/dev/null 2>&1; then
    fail "htpasswd unavailable — install apache2-utils manually"
    return 3
  fi

  local hash mtime password_key mtime_key
  hash=$(htpasswd -nbBC 10 "" "$pw" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
  mtime=$(date +%FT%T%Z)

  case "$account" in
    admin)
      password_key="admin.password"
      mtime_key="admin.passwordMtime"
      ;;
    *)
      password_key="accounts.${account}.password"
      mtime_key="accounts.${account}.passwordMtime"
      ;;
  esac

  if "${KUBECTL[@]}" -n argocd patch secret argocd-secret --type merge \
       -p "{\"stringData\":{\"$password_key\":\"$hash\",\"$mtime_key\":\"$mtime\"}}" \
       >/dev/null; then
    pass "argocd account '$account' password updated"
    return 0
  fi
  fail "could not patch argocd-secret for account '$account'"
  return 1
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 18 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/argocd_users.sh tests/bash/argocd_users.bats
git commit -m "bootstrap(lib): extract _argocd_set_account_password supporting per-account keys"
```

---

## Task 7: Wire `argocd_users` phase in `bootstrap-robot.sh`

**Files:**
- Modify: `scripts/bootstrap-robot.sh` ([`argocd_admin()` at line ~2057](../../../scripts/bootstrap-robot.sh#L2057), arg-parsing at line ~232)

- [ ] **Step 1: Add a failing integration-shape test**

Append to `tests/bash/argocd_users.bats`:

```bash
@test "argocd_users phase calls _argocd_set_account_password for admin, operator, fleet-operator" {
  # Source bootstrap in lib mode and stub the password reader.
  BOOTSTRAP_LIB_ONLY=1 source "$REPO_ROOT/scripts/bootstrap-robot.sh"
  _read_argocd_password() { echo "stub-pw-${1}"; }   # stubbed prompt

  KUBECTL=(kubectl)
  SKIP_ARGOCD_USERS=0
  DRY_RUN=0
  argocd_users 2>/dev/null

  grep -q 'admin.password' "$STUB_LOG_KUBECTL"
  grep -q 'accounts.operator.password' "$STUB_LOG_KUBECTL"
  grep -q 'accounts.fleet-operator.password' "$STUB_LOG_KUBECTL"
}
```

- [ ] **Step 2: Run — expect FAIL**

`argocd_users` doesn't exist yet (still named `argocd_admin`); the test will error.

- [ ] **Step 3: In `scripts/bootstrap-robot.sh`, source the new lib**

Near the top of the script (after `# ---- helpers ---` block, around line 300):

```bash
# Load extracted user-mgmt helpers.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/argocd_users.sh"
```

- [ ] **Step 4: Add `_read_argocd_password` helper**

Insert just above the existing `argocd_admin()` (around line 2055):

```bash
# Prompt twice for a password with echo off; default to "1984" on empty
# input. Non-interactive shells get the default. Stubbed in tests.
_read_argocd_password() {
  local account="${1:-admin}" default_pw="${_argocd_default_password:-1984}"
  local pw_a pw_b
  if [ -t 0 ] && [ -t 2 ]; then
    while :; do
      printf '  argocd %s password [%s]: ' "$account" "$default_pw" >&2
      stty -echo 2>/dev/null || true
      IFS= read -r pw_a || pw_a=""
      stty echo 2>/dev/null || true
      printf '\n' >&2
      pw_a="${pw_a:-$default_pw}"
      printf '  confirm: ' >&2
      stty -echo 2>/dev/null || true
      IFS= read -r pw_b || pw_b=""
      stty echo 2>/dev/null || true
      printf '\n' >&2
      pw_b="${pw_b:-$default_pw}"
      [ "$pw_a" = "$pw_b" ] && break
      printf '  passwords do not match — try again\n' >&2
    done
    printf '%s' "$pw_a"
  else
    printf '%s' "$default_pw"
  fi
}
```

- [ ] **Step 5: Replace `argocd_admin()` with `argocd_users()`**

Locate the function at [bootstrap-robot.sh:2057](../../../scripts/bootstrap-robot.sh#L2057) and replace it with:

```bash
argocd_users() {
  if [ "${SKIP_ARGOCD_USERS:-${SKIP_ARGOCD_ADMIN:-1}}" = 1 ]; then
    phase "phase 9: argocd users  (skipped)"; return
  fi
  phase "phase 9: argocd users (install CLI + set admin/operator/fleet-operator passwords)"

  # 1) install argocd CLI (existing logic preserved)
  _install_argocd_cli || return

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  prompt for admin/operator/fleet-operator passwords"
    info "DRY-RUN  patch argocd-secret with bcrypt(\$pw) for each account"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch argocd-secret"; return
  fi
  if ! "${KUBECTL[@]}" -n argocd get secret argocd-secret >/dev/null 2>&1; then
    fail "argocd-secret not found in argocd ns — gitops phase must run first"; return
  fi

  local account pw
  for account in admin operator fleet-operator; do
    pw="$(_read_argocd_password "$account")"
    _argocd_set_account_password "$account" "$pw" || true
  done

  "${KUBECTL[@]}" -n argocd delete secret argocd-initial-admin-secret \
      --ignore-not-found >/dev/null 2>&1 || true
}

# Backwards-compat alias so external runbooks pinned to argocd_admin still work.
argocd_admin() { argocd_users "$@"; }
```

Then extract the CLI-install block from the original `argocd_admin()` into `_install_argocd_cli()` defined just above `argocd_users()` — copy lines 2061–2111 of the original and wrap in `_install_argocd_cli() { ... }`.

- [ ] **Step 6: Update arg-parsing for `--argocd-users`**

At [bootstrap-robot.sh:249](../../../scripts/bootstrap-robot.sh#L249) replace:

```bash
    --argocd-admin)      SELECTED_PHASES+=(argocd-admin); shift ;;
```

with:

```bash
    --argocd-users|--argocd-admin)
                          SELECTED_PHASES+=(argocd-users); shift ;;
```

And at [bootstrap-robot.sh:446](../../../scripts/bootstrap-robot.sh#L446) replace:

```bash
      argocd-admin)      SKIP_ARGOCD_ADMIN=0 ;;
```

with:

```bash
      argocd-users|argocd-admin) SKIP_ARGOCD_USERS=0 ;;
```

Search for the remaining occurrences of `SKIP_ARGOCD_ADMIN` and `argocd_admin       ; guard` in the final phase-call block and update to `SKIP_ARGOCD_USERS` / `argocd_users      ; guard`.

- [ ] **Step 7: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 19 tests, 0 failures.

- [ ] **Step 8: Smoke-run `--help` and `--dry-run --argocd-users`**

```bash
bash scripts/bootstrap-robot.sh --help | grep -q argocd-users
DRY_RUN=1 bash scripts/bootstrap-robot.sh --dry-run --argocd-users 2>&1 | tail -10
```

Expected: help mentions `--argocd-users`; dry-run prints `DRY-RUN  prompt for admin/operator/fleet-operator passwords` and exits 0.

- [ ] **Step 9: Commit**

```bash
git add scripts/bootstrap-robot.sh tests/bash/argocd_users.bats
git commit -m "bootstrap: rename argocd_admin → argocd_users, set admin/operator/fleet-operator passwords"
```

---

## Task 8: `_apply_repo_credential` library + bootstrap wiring

**Files:**
- Create: `scripts/lib/repo_credential.sh`
- Create: `tests/bash/repo_credential.bats`
- Create: `host-config-templates/_template/argocd-repo-credential.yaml.tpl`
- Modify: `scripts/bootstrap-robot.sh` (`gitops()` phase)
- Modify: `.gitignore`

- [ ] **Step 1: Write failing tests**

```bash
# tests/bash/repo_credential.bats
load 'helpers/load'
setup() {
  setup_common
  source "$REPO_ROOT/scripts/lib/repo_credential.sh" 2>/dev/null || true
  pass()  { :; }
  fail()  { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }
  info()  { :; }
  note()  { :; }
  KUBECTL=(kubectl)
  FAIL=0
}

_make_creds() {
  # writes a minimally-valid credential YAML with mode 0600 and returns its path
  local f="$BATS_TEST_TMPDIR/creds.yaml"
  cat > "$f" <<'YAML'
apiVersion: v1
kind: Secret
metadata: {name: phantomos-kos-repo, namespace: argocd, labels: {argocd.argoproj.io/secret-type: repository}}
stringData: {type: git, url: "https://github.com/foundationbot/Phantom-OS-KubernetesOptions", username: x-access-token, password: ghp_xxxxxxxx}
YAML
  chmod 0600 "$f"; printf '%s' "$f"
}

@test "_validate_repo_credential_file rejects mode 0644" {
  f="$(_make_creds)"; chmod 0644 "$f"
  run _validate_repo_credential_file "$f"
  [ "$status" -ne 0 ]
}

@test "_validate_repo_credential_file accepts mode 0600" {
  f="$(_make_creds)"
  run _validate_repo_credential_file "$f"
  [ "$status" -eq 0 ]
}

@test "_validate_repo_credential_file rejects path inside a git work tree" {
  f="$BATS_TEST_TMPDIR/repo/creds.yaml"
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  ( cd "$BATS_TEST_TMPDIR/repo" && git init -q )
  cp "$(_make_creds)" "$f"; chmod 0600 "$f"
  run _validate_repo_credential_file "$f"
  [ "$status" -ne 0 ]
  [[ "$output" =~ git ]] || [[ "$output" =~ work ]]
}

@test "_apply_repo_credential applies via kubectl and polls argocd repo list" {
  f="$(_make_creds)"
  _apply_repo_credential "$f"
  grep -q 'apply -n argocd' "$STUB_LOG_KUBECTL"
  grep -q 'repo list' "$STUB_LOG_ARGOCD"
}

@test "_apply_repo_credential fails loud if kubectl apply fails" {
  f="$(_make_creds)"
  STUB_KUBECTL_FAIL=1 run _apply_repo_credential "$f"
  [ "$FAIL" -gt 0 ] || [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run — expect FAIL** (`scripts/lib/repo_credential.sh` missing)

- [ ] **Step 3: Write `scripts/lib/repo_credential.sh`**

```bash
# scripts/lib/repo_credential.sh — apply the ArgoCD repository Secret from a
# file on disk. Used by bootstrap-robot.sh during the gitops phase. Sourced
# by bats tests with stubbed kubectl/argocd. Depends on KUBECTL[] and the
# logging helpers (pass/fail/info/note) from the caller.

REPO_CREDENTIAL_CANONICAL_PATH="${REPO_CREDENTIAL_CANONICAL_PATH:-/etc/phantomos/argocd-repo-credential.yaml}"
ARGOCD_REPO_SECRET_NAME="${ARGOCD_REPO_SECRET_NAME:-phantomos-kos-repo}"

# _validate_repo_credential_file <path>
#   Returns 0 if file is mode 0600, owned by root (skipped in tests), and
#   not inside a git work tree. Else returns non-zero with a clear stderr
#   message.
_validate_repo_credential_file() {
  local f="${1:?path required}"
  if [ ! -r "$f" ]; then
    echo "credential file not readable: $f" >&2; return 2
  fi
  local mode
  mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")
  if [ "$mode" != "600" ]; then
    echo "credential file mode must be 0600 (got $mode): $f" >&2; return 3
  fi
  # Reject paths inside a git work tree to prevent accidental commits.
  if ( cd "$(dirname "$f")" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    echo "credential file is inside a git work tree: $f" >&2; return 4
  fi
  return 0
}

# _apply_repo_credential <path>
#   Validates and applies the credential file. Polls `argocd repo list`
#   for connection status; fails loudly if not Successful within the
#   timeout.
_apply_repo_credential() {
  local f="${1:?path required}"
  _validate_repo_credential_file "$f" || { fail "credential file rejected"; return 1; }

  if ! "${KUBECTL[@]}" apply -n argocd -f "$f" >/dev/null; then
    fail "kubectl apply of repo credential failed"; return 1
  fi
  pass "applied ArgoCD repo credential from $f"

  # Annotate any existing Application to force a fresh repo connection.
  "${KUBECTL[@]}" -n argocd get application -o name 2>/dev/null \
    | xargs -r -I{} "${KUBECTL[@]}" -n argocd annotate {} \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

  # Poll: argocd repo list reports Successful within 60s.
  local i
  for i in $(seq 1 30); do
    if argocd repo list 2>/dev/null | grep -q 'Successful'; then
      pass "argocd repo list reports Successful"
      return 0
    fi
    sleep 2
  done
  fail "argocd repo list did not reach Successful within 60s"
  return 1
}
```

- [ ] **Step 4: Write `host-config-templates/_template/argocd-repo-credential.yaml.tpl`**

```yaml
# Template for /etc/phantomos/argocd-repo-credential.yaml.
#
# Copy to the canonical path (mode 0600, owner root:root) and replace the
# placeholders. NEVER commit the filled file to git; bootstrap will refuse
# to apply it from inside a git work tree.
#
#   sudo install -m 0600 -o root -g root \
#       argocd-repo-credential.yaml /etc/phantomos/argocd-repo-credential.yaml
#
# Two variants — keep ONE block, delete the other.
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
  # ---- Variant A: GitHub App (preferred) -------------------------------
  githubAppID: "REPLACE-WITH-APP-ID"
  githubAppInstallationID: "REPLACE-WITH-INSTALLATION-ID"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    REPLACE-WITH-PRIVATE-KEY-LINES
    -----END RSA PRIVATE KEY-----
  # ---- Variant B: fine-grained PAT (fallback) --------------------------
  # username: x-access-token
  # password: REPLACE-WITH-PAT
```

- [ ] **Step 5: Update root `.gitignore`**

Append (or create if missing):

```
# Never commit a filled repo credential — bootstrap also enforces this.
argocd-repo-credential.yaml
**/argocd-repo-credential.yaml
!host-config-templates/_template/argocd-repo-credential.yaml.tpl
```

- [ ] **Step 6: Source the lib + add `--repo-credential-file` arg**

In `scripts/bootstrap-robot.sh`, just below the `argocd_users.sh` source line added in Task 7:

```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/repo_credential.sh"
```

In the arg-parsing block (around line 235), add:

```bash
    --repo-credential-file)
        REPO_CREDENTIAL_FILE="${2:?value required}"; shift 2 ;;
```

Default near other `DEFAULT_*=` (around line 986):

```bash
REPO_CREDENTIAL_FILE="${REPO_CREDENTIAL_FILE:-/etc/phantomos/argocd-repo-credential.yaml}"
```

- [ ] **Step 7: Hook `_apply_repo_credential` into `gitops()`**

In `gitops()` (around line 1077), after the terraform apply step and **before** `_gitops_render_app`, add:

```bash
  # Apply repo credential so argocd-repo-server can clone the (private) repo
  # before any Application CR is reconciled.
  if [ -r "$REPO_CREDENTIAL_FILE" ]; then
    _apply_repo_credential "$REPO_CREDENTIAL_FILE" || guard
  else
    fail "repo credential not found at $REPO_CREDENTIAL_FILE — pass --repo-credential-file or pre-stage the file"
    return
  fi
```

- [ ] **Step 8: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 24 tests, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/repo_credential.sh tests/bash/repo_credential.bats \
        host-config-templates/_template/argocd-repo-credential.yaml.tpl \
        scripts/bootstrap-robot.sh .gitignore
git commit -m "bootstrap: apply ArgoCD repo credential from /etc/phantomos at gitops phase"
```

---

## Task 9: Apply secret-RBAC + ArgoCD-RBAC overlays in `gitops()`

**Files:**
- Modify: `scripts/bootstrap-robot.sh` (`gitops()`)
- Create: `tests/bash/gitops_rbac.bats`

- [ ] **Step 1: Write failing test**

```bash
# tests/bash/gitops_rbac.bats
load 'helpers/load'
setup() {
  setup_common
  BOOTSTRAP_LIB_ONLY=1 source "$REPO_ROOT/scripts/bootstrap-robot.sh"
  KUBECTL=(kubectl)
}

@test "_gitops_apply_secret_rbac applies argocd-secret-rbac overlay" {
  _gitops_apply_secret_rbac
  grep -q 'apply -k.*manifests/base/argocd-secret-rbac' "$STUB_LOG_KUBECTL"
}

@test "_gitops_apply_argocd_user_rbac applies argocd-rbac overlay" {
  _gitops_apply_argocd_user_rbac
  grep -q 'apply -k.*manifests/base/argocd-rbac' "$STUB_LOG_KUBECTL"
}

@test "_gitops_apply_argocd_user_rbac applies fleet-operator kubectl-rbac overlay" {
  _gitops_apply_argocd_user_rbac
  grep -q 'apply -k.*manifests/base/fleet-operator-kubectl-rbac' "$STUB_LOG_KUBECTL"
}
```

- [ ] **Step 2: Run — expect FAIL**

Functions don't exist yet.

- [ ] **Step 3: Add the two functions to `scripts/bootstrap-robot.sh`**

Insert just above `gitops()` (around line 1075):

```bash
_gitops_apply_secret_rbac() {
  "${KUBECTL[@]}" apply -k "$REPO_ROOT/manifests/base/argocd-secret-rbac" >/dev/null \
    && pass "applied argocd-secret-rbac overlay" \
    || { fail "could not apply argocd-secret-rbac overlay"; return 1; }
}

_gitops_apply_argocd_user_rbac() {
  "${KUBECTL[@]}" apply -k "$REPO_ROOT/manifests/base/argocd-rbac" >/dev/null \
    && pass "applied argocd-rbac (operator + fleet-operator accounts)" \
    || { fail "could not apply argocd-rbac overlay"; return 1; }
  "${KUBECTL[@]}" apply -k "$REPO_ROOT/manifests/base/fleet-operator-kubectl-rbac" >/dev/null \
    && pass "applied fleet-operator-kubectl-rbac" \
    || { fail "could not apply fleet-operator-kubectl-rbac"; return 1; }
}
```

- [ ] **Step 4: Call them from `gitops()`**

In `gitops()`, immediately after the terraform apply and **before** `_apply_repo_credential`:

```bash
  _gitops_apply_secret_rbac || guard
  _gitops_apply_argocd_user_rbac || guard
```

- [ ] **Step 5: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 27 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap-robot.sh tests/bash/gitops_rbac.bats
git commit -m "bootstrap: apply secret-RBAC and ArgoCD-RBAC overlays in gitops phase"
```

---

## Task 10: etcd encryption-at-rest in `deps()`

**Files:**
- Create: `scripts/lib/etcd_encryption.sh`
- Create: `tests/bash/etcd_encryption.bats`
- Modify: `scripts/bootstrap-robot.sh` (`deps()` phase)

- [ ] **Step 1: Write failing tests**

```bash
# tests/bash/etcd_encryption.bats
load 'helpers/load'
setup() {
  setup_common
  source "$REPO_ROOT/scripts/lib/etcd_encryption.sh" 2>/dev/null || true
  pass()  { :; }; fail()  { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }; info()  { :; }
  FAIL=0
  ETCD_ENCRYPTION_CONFIG_PATH="$BATS_TEST_TMPDIR/encryption-config.yaml"
  ETCD_ENCRYPTION_KEY_BACKUP_PATH="$BATS_TEST_TMPDIR/etcd-encryption-key.bak"
}

@test "_ensure_etcd_encryption_config generates a fresh key on first run" {
  run _ensure_etcd_encryption_config
  [ "$status" -eq 0 ]
  [ -f "$ETCD_ENCRYPTION_CONFIG_PATH" ]
  grep -q 'kind: EncryptionConfiguration' "$ETCD_ENCRYPTION_CONFIG_PATH"
  grep -qE 'aescbc:' "$ETCD_ENCRYPTION_CONFIG_PATH"
  # 32-byte base64 key = ~44 chars
  grep -qE 'secret:\s+[A-Za-z0-9+/]{40,}=*' "$ETCD_ENCRYPTION_CONFIG_PATH"
}

@test "_ensure_etcd_encryption_config writes file with mode 0600" {
  _ensure_etcd_encryption_config
  mode=$(stat -c '%a' "$ETCD_ENCRYPTION_CONFIG_PATH")
  [ "$mode" = "600" ]
}

@test "_ensure_etcd_encryption_config writes a backup key" {
  _ensure_etcd_encryption_config
  [ -f "$ETCD_ENCRYPTION_KEY_BACKUP_PATH" ]
  mode=$(stat -c '%a' "$ETCD_ENCRYPTION_KEY_BACKUP_PATH")
  [ "$mode" = "600" ]
}

@test "_ensure_etcd_encryption_config is idempotent — does not regenerate the key" {
  _ensure_etcd_encryption_config
  before=$(sha256sum "$ETCD_ENCRYPTION_CONFIG_PATH" | awk '{print $1}')
  _ensure_etcd_encryption_config
  after=$(sha256sum "$ETCD_ENCRYPTION_CONFIG_PATH" | awk '{print $1}')
  [ "$before" = "$after" ]
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Write `scripts/lib/etcd_encryption.sh`**

```bash
# scripts/lib/etcd_encryption.sh — generate / install k0s EncryptionConfiguration.
# Sourced by bootstrap-robot.sh during deps phase, before k0s starts so all
# Secrets land encrypted on first write. Unit-tested via bats.

ETCD_ENCRYPTION_CONFIG_PATH="${ETCD_ENCRYPTION_CONFIG_PATH:-/var/lib/k0s/pki/encryption-config.yaml}"
ETCD_ENCRYPTION_KEY_BACKUP_PATH="${ETCD_ENCRYPTION_KEY_BACKUP_PATH:-/etc/phantomos/etcd-encryption-key.bak}"
ETCD_ENCRYPTION_KEY_NAME="${ETCD_ENCRYPTION_KEY_NAME:-phantomos-v1}"

_ensure_etcd_encryption_config() {
  if [ -f "$ETCD_ENCRYPTION_CONFIG_PATH" ]; then
    info "etcd encryption config already present at $ETCD_ENCRYPTION_CONFIG_PATH"
    return 0
  fi

  mkdir -p "$(dirname "$ETCD_ENCRYPTION_CONFIG_PATH")" || {
    fail "cannot create $(dirname "$ETCD_ENCRYPTION_CONFIG_PATH")"; return 1
  }

  local key
  key=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

  umask 077
  cat > "$ETCD_ENCRYPTION_CONFIG_PATH" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: $ETCD_ENCRYPTION_KEY_NAME
              secret: $key
      - identity: {}
EOF
  chmod 0600 "$ETCD_ENCRYPTION_CONFIG_PATH"

  mkdir -p "$(dirname "$ETCD_ENCRYPTION_KEY_BACKUP_PATH")"
  printf '%s\n' "$key" > "$ETCD_ENCRYPTION_KEY_BACKUP_PATH"
  chmod 0600 "$ETCD_ENCRYPTION_KEY_BACKUP_PATH"

  pass "generated k0s etcd encryption config + backup key"
  return 0
}
```

- [ ] **Step 4: Source the lib in `bootstrap-robot.sh` and call from `deps()`**

Source line, alongside the other `lib/` sources:

```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/etcd_encryption.sh"
```

In `deps()` ([line ~915](../../../scripts/bootstrap-robot.sh#L915)), as the **first** step (before any apt installs that might pull k0s):

```bash
  _ensure_etcd_encryption_config || guard
```

Also wire k0s to load it: in `cluster()` ([line ~1050](../../../scripts/bootstrap-robot.sh#L1050)) — find the k0s install/start block and add `--api-server-extra-args=--encryption-provider-config=$ETCD_ENCRYPTION_CONFIG_PATH` (k0s syntax may differ — verify against k0s docs and the existing flags in that block; the corresponding key in `k0s.yaml` is `spec.api.extraArgs.encryption-provider-config`).

- [ ] **Step 5: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 31 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/etcd_encryption.sh tests/bash/etcd_encryption.bats scripts/bootstrap-robot.sh
git commit -m "bootstrap(deps): generate k0s etcd EncryptionConfiguration before cluster start"
```

---

## Task 11: Partial-phase CLI flags `--gitops-repo-credential-only` and `--gitops-rbac-only`

**Why:** the migration playbook ([RFC §"Migration for already-deployed robots"](../../rfcs/0002-private-repo-argocd-auth.md)) needs to apply just one piece without re-running every phase.

**Files:**
- Modify: `scripts/bootstrap-robot.sh`
- Create: `tests/bash/partial_phases.bats`

- [ ] **Step 1: Write failing test**

```bash
# tests/bash/partial_phases.bats
load 'helpers/load'
setup() { setup_common; }

@test "--gitops-repo-credential-only runs only the credential apply step" {
  # Use --dry-run so it doesn't touch the system; we just verify selected phases.
  run bash "$REPO_ROOT/scripts/bootstrap-robot.sh" --dry-run \
      --gitops-repo-credential-only --repo-credential-file /dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'apply repo credential'
  ! echo "$output" | grep -qE '\bphase 1: preflight\b'
  ! echo "$output" | grep -qE '\bphase 2: deps\b'
}

@test "--gitops-rbac-only runs only the RBAC overlay applies" {
  run bash "$REPO_ROOT/scripts/bootstrap-robot.sh" --dry-run --gitops-rbac-only
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'apply argocd-secret-rbac'
  echo "$output" | grep -q 'apply argocd-rbac'
  ! echo "$output" | grep -qE '\bphase 2: deps\b'
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Add the flags to arg-parsing**

In `scripts/bootstrap-robot.sh` arg-parsing (around [line 232](../../../scripts/bootstrap-robot.sh#L232)):

```bash
    --gitops-repo-credential-only)
        SELECTED_PHASES+=(gitops-repo-credential-only); shift ;;
    --gitops-rbac-only)
        SELECTED_PHASES+=(gitops-rbac-only); shift ;;
```

- [ ] **Step 4: Add narrow phase entrypoints**

Above the final phase-call block:

```bash
gitops_repo_credential_only() {
  phase "phase: apply repo credential (only)"
  if [ "$DRY_RUN" = 1 ]; then info "DRY-RUN  apply repo credential from $REPO_CREDENTIAL_FILE"; return; fi
  _apply_repo_credential "$REPO_CREDENTIAL_FILE"
}

gitops_rbac_only() {
  phase "phase: apply argocd RBAC overlays (only)"
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  apply argocd-secret-rbac"
    info "DRY-RUN  apply argocd-rbac"
    info "DRY-RUN  apply fleet-operator-kubectl-rbac"
    return
  fi
  _gitops_apply_secret_rbac
  _gitops_apply_argocd_user_rbac
}
```

- [ ] **Step 5: Wire phase selection**

When `SELECTED_PHASES` contains either of the two new entries, the existing dispatcher should set every other `SKIP_*` flag to `1` and call only the matching narrow function. Find the dispatcher block (around [line 365–460](../../../scripts/bootstrap-robot.sh#L365)) and extend the case statement to skip everything else when one of these is selected, then directly invoke `gitops_repo_credential_only` / `gitops_rbac_only` instead of the standard phase chain.

(Concrete diff depends on the dispatcher's exact shape; the test pins the contract.)

- [ ] **Step 6: Run tests — expect PASS**

Run: `make -C tests/bash test`
Expected: 33 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap-robot.sh tests/bash/partial_phases.bats
git commit -m "bootstrap: --gitops-repo-credential-only / --gitops-rbac-only for migration playbook"
```

---

## Task 12: Update `docs/operations.md` with runbooks

**Files:**
- Modify: [`docs/operations.md`](../../operations.md)

- [ ] **Step 1: Read the existing operations.md to match style**

Run: `wc -l docs/operations.md && head -40 docs/operations.md`
Expected: get a sense of section ordering + heading style.

- [ ] **Step 2: Append three new sections**

Append to `docs/operations.md`:

```markdown
## Issuing a fleet-operator kubeconfig

The `fleet-operator` ServiceAccount is installed by
`manifests/base/fleet-operator-kubectl-rbac/`. To hand a kubeconfig to an
on-call operator:

```bash
ROBOT=<robot-name>
SA_NS=kube-system
SA=fleet-operator
SECRET=$(kubectl -n $SA_NS create token $SA --duration=720h)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
cat > "$ROBOT-fleet-operator.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $ROBOT
  cluster:
    server: $APISERVER
    certificate-authority-data: $CA
contexts:
- name: $ROBOT
  context: {cluster: $ROBOT, user: fleet-operator, namespace: default}
users:
- name: fleet-operator
  user: {token: $SECRET}
current-context: $ROBOT
EOF
chmod 0600 "$ROBOT-fleet-operator.kubeconfig"
```

Verify: `kubectl --kubeconfig=...kubeconfig get ns` succeeds; `kubectl ...
get secret -n argocd phantomos-kos-repo` returns `Forbidden`; `kubectl ...
scale deploy/foo --replicas=2 -n nimbus` succeeds; `kubectl ... delete ns
nimbus` returns `Forbidden`.

## Rotating the ArgoCD repo credential

1. Render a fresh `argocd-repo-credential.yaml` from
   `host-config-templates/_template/argocd-repo-credential.yaml.tpl` with
   the new GitHub App key (or PAT). `chmod 0600`.
2. For each robot:
   ```
   scp -p argocd-repo-credential.yaml \
       root@$ROBOT:/etc/phantomos/argocd-repo-credential.yaml
   ssh root@$ROBOT 'bootstrap-robot.sh --gitops-repo-credential-only'
   ```
3. Verify on the robot: `argocd repo list` reports `Successful`.
4. After the fan-out, revoke the old GitHub App installation key.

## Recovering a lost etcd encryption key

The encryption key lives at `/var/lib/k0s/pki/encryption-config.yaml` with
a backup at `/etc/phantomos/etcd-encryption-key.bak`. If both are lost:

- All Secrets in etcd become unreadable. The cluster keeps running but new
  pods that need those Secrets will fail.
- Recover by re-bootstrapping (`bootstrap-robot.sh --gitops`) which
  generates a fresh key and re-applies the repo credential. Any Secret not
  re-applied (e.g. operator-installed app secrets) must be manually
  recreated.

To prevent loss: `cp /var/lib/k0s/pki/encryption-config.yaml
/etc/phantomos/etcd-encryption-key.bak` is a no-op once bootstrap has run,
so as long as `/etc/phantomos/` is on a separate partition from
`/var/lib/`, single-disk failures won't take both copies.
```

- [ ] **Step 3: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): fleet-operator kubeconfig, repo cred rotation, etcd key recovery"
```

---

## Task 13: End-to-end test on a dev robot

**This task is manual** — there is no automated equivalent because it runs against a real k0s cluster with real ArgoCD.

**Files:** none modified by this task.

- [ ] **Step 1: Pick a non-production robot and a fork of this repo**

Pick a dev robot reachable via Tailscale. Fork `Phantom-OS-KubernetesOptions`
to a personal namespace and **set the fork private** in GitHub.

- [ ] **Step 2: Provision a test GitHub App**

In the GitHub UI: Settings → Developer settings → GitHub Apps → New App.
Permissions: `Contents: Read` on the fork. Install on the fork. Download
the App's `.pem` private key.

- [ ] **Step 3: Render the credential file locally**

Copy `host-config-templates/_template/argocd-repo-credential.yaml.tpl`,
fill in App ID / install ID / paste the PEM, `chmod 0600`. Keep this file
on your workstation only — never copy into the repo working tree.

- [ ] **Step 4: Run the full bringup**

```bash
sudo install -m 0600 argocd-repo-credential.yaml /etc/phantomos/
sudo bash scripts/bootstrap-robot.sh --gitops --argocd-users
```

Expected: `phase 6: gitops` reports `applied argocd-secret-rbac overlay`,
`applied argocd-rbac (operator + fleet-operator accounts)`, `applied
fleet-operator-kubectl-rbac`, `applied ArgoCD repo credential`, `argocd
repo list reports Successful`. `phase 9: argocd users` prompts three
times and patches three accounts.

- [ ] **Step 5: Verify ArgoCD account RBAC**

```bash
argocd login <robot>:30443 --username operator       # use password set in step 4
argocd app sync phantomos-<robot>-core               # expect: permission denied
argocd app get phantomos-<robot>-core                # expect: success
argocd logout
argocd login <robot>:30443 --username fleet-operator
argocd app sync phantomos-<robot>-core               # expect: success
argocd app delete phantomos-<robot>-core             # expect: permission denied
argocd repo get https://github.com/.../<fork>        # expect: redacted password fields
```

- [ ] **Step 6: Verify K8s RBAC**

Issue a fleet-operator kubeconfig per
[`docs/operations.md`](../../operations.md). Then:

```bash
kubectl --kubeconfig=fleet-operator.kubeconfig -n argocd get secret phantomos-kos-repo
# expect: Forbidden
kubectl --kubeconfig=fleet-operator.kubeconfig scale deploy/<existing-deploy> --replicas=2 -n <some-ns>
# expect: scaled
kubectl --kubeconfig=fleet-operator.kubeconfig delete ns nimbus
# expect: Forbidden
```

- [ ] **Step 7: Verify etcd encryption-at-rest**

```bash
sudo k0s etcd ctl get /registry/secrets/argocd/phantomos-kos-repo
# expect: prefix "k8s:enc:aescbc:v1:phantomos-v1:" + ciphertext (NOT the PEM)
```

- [ ] **Step 8: Push a manifest change to the fork; observe reconcile**

Edit any `manifests/stacks/core/...` file in the fork, commit, push.
Within ~3 minutes (default refresh interval), `argocd app get
phantomos-<robot>-core` shows the new commit SHA and `Synced/Healthy`.

- [ ] **Step 9: Revoke the test App; confirm fail-closed**

In the fork's GitHub Settings → Installed Apps → Suspend the test App.
Within a minute, `kubectl -n argocd logs deploy/argocd-repo-server` shows
401s and `argocd app sync` fails with auth error. Workloads keep running.

- [ ] **Step 10: Document any drift**

If any step diverges from this plan, capture it in
`docs/superpowers/notes/2026-05-04-private-repo-argocd-auth-e2e.md` so the
next implementer knows. No commit required if everything passes.

---

## Self-review checklist (run before handing off)

- [ ] Every RFC 0002 v1 goal maps to a task: ArgoCD-can-auth (T8), bootstrap-provisions-cred (T8), already-deployed-migration (T11), rotation (T8+T12), file-not-on-disk-broader-than-0600 (T8), namespace-RBAC (T2+T9), ArgoCD-user-RBAC (T3+T7), kubectl-RBAC (T4+T9), etcd-at-rest (T10).
- [ ] No "TBD" / "implement appropriate" / "see RFC" placeholders.
- [ ] Function names are consistent: `_argocd_set_account_password`, `_apply_repo_credential`, `_validate_repo_credential_file`, `_gitops_apply_secret_rbac`, `_gitops_apply_argocd_user_rbac`, `_ensure_etcd_encryption_config`, `argocd_users`. Each appears identically wherever referenced.
- [ ] CLI flags consistent: `--argocd-users` (with `--argocd-admin` alias), `--repo-credential-file`, `--gitops-repo-credential-only`, `--gitops-rbac-only`.
- [ ] File paths consistent: `/etc/phantomos/argocd-repo-credential.yaml`, `/var/lib/k0s/pki/encryption-config.yaml`, `/etc/phantomos/etcd-encryption-key.bak`, `manifests/base/argocd-secret-rbac/`, `manifests/base/argocd-rbac/`, `manifests/base/fleet-operator-kubectl-rbac/`.
- [ ] AWS-source path is **not** in v1; it's mentioned only in the RFC's "v2 deferred" section and not referenced in any task here.
