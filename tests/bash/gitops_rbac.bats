# tests/bash/gitops_rbac.bats
load 'helpers/load'
setup() {
  setup_common
  BOOTSTRAP_LIB_ONLY=1 source "$REPO_ROOT/scripts/bootstrap-robot.sh"
  KUBECTL=(kubectl)
}

@test "_gitops_apply_secret_rbac applies argocd-secret-rbac overlay via kubectl apply -k" {
  _gitops_apply_secret_rbac
  grep -q 'apply -k.*manifests/base/argocd-secret-rbac' "$STUB_LOG_KUBECTL"
}

@test "_gitops_apply_argocd_user_rbac patches argocd-cm and argocd-rbac-cm" {
  _gitops_apply_argocd_user_rbac
  grep -q 'patch configmap argocd-cm' "$STUB_LOG_KUBECTL"
  grep -q 'patch configmap argocd-rbac-cm' "$STUB_LOG_KUBECTL"
}

@test "_gitops_apply_argocd_user_rbac applies fleet-operator-kubectl-rbac via kubectl apply -k" {
  _gitops_apply_argocd_user_rbac
  grep -q 'apply -k.*manifests/base/fleet-operator-kubectl-rbac' "$STUB_LOG_KUBECTL"
}
