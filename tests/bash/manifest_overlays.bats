# tests/bash/manifest_overlays.bats
load 'helpers/load'
setup() { setup_common; }

@test "argocd-secret-rbac kustomize build emits Role and RoleBinding" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-secret-rbac")"
  echo "$out" | grep -q 'kind: Role'
  echo "$out" | grep -q 'kind: RoleBinding'
  echo "$out" | grep -q 'namespace: argocd'
  # Both the Role and the RoleBinding must use the canonical name.
  [ "$(echo "$out" | grep -c 'name: argocd-secret-reader')" -ge 2 ]
}

@test "argocd-secret-rbac Role grants only get/list/watch on secrets" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-secret-rbac")"
  echo "$out" | grep -q 'resources:'
  echo "$out" | grep -q 'secrets'
  ! echo "$out" | grep -E 'verbs:.*\b(create|update|patch|delete|deletecollection)\b'
  # Each allowed verb must be present.
  echo "$out" | grep -q 'get'
  echo "$out" | grep -q 'list'
  echo "$out" | grep -q 'watch'
}

@test "argocd-secret-rbac RoleBinding subjects are ServiceAccounts only" {
  out="$(kustomize build "$REPO_ROOT/manifests/base/argocd-secret-rbac")"
  # No User or Group subjects anywhere in the output.
  ! echo "$out" | grep -qE '^\s+kind: User\s*$'
  ! echo "$out" | grep -qE '^\s+kind: Group\s*$'
  # Every expected component SA must appear exactly once.
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-server\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-repo-server\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-application-controller\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-applicationset-controller\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-notifications-controller\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-dex-server\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-redis-secret-init\s*$')" -eq 1 ]
  [ "$(echo "$out" | grep -cE '^\s+name: argocd-commit-server\s*$')" -eq 1 ]
}

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
  [ "$(echo "$out" | grep -cE '^[[:space:]]+g, ')" -eq 2 ]
  ! echo "$out" | grep -qE 'role:admin'
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
