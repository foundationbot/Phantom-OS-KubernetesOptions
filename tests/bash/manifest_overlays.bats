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
