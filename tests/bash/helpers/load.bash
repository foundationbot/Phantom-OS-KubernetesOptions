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
