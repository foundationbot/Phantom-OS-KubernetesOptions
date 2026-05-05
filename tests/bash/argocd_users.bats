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
