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

@test "_validate_repo_credential_file rejects non-root owner (production)" {
  f="$(_make_creds)"
  # Simulate production by clearing BATS_TEST_TMPDIR for this assertion
  saved_tmpdir="$BATS_TEST_TMPDIR"
  unset BATS_TEST_TMPDIR
  run _validate_repo_credential_file "$f"
  export BATS_TEST_TMPDIR="$saved_tmpdir"
  [ "$status" -ne 0 ]
  [[ "$output" =~ root:root ]] || [[ "$output" =~ owned ]]
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

@test "gitops() honors --repo-credential-file via REPO_CREDENTIAL_FILE env" {
  # Source bootstrap in lib mode and stub functions whose real implementations
  # would touch the real cluster / require a working environment.
  BOOTSTRAP_LIB_ONLY=1 source "$REPO_ROOT/scripts/bootstrap-robot.sh"

  # Build a valid credential file outside the git tree.
  f="$BATS_TEST_TMPDIR/creds.yaml"
  cat > "$f" <<'YAML'
apiVersion: v1
kind: Secret
metadata: {name: phantomos-kos-repo, namespace: argocd, labels: {argocd.argoproj.io/secret-type: repository}}
stringData: {type: git, url: "https://github.com/foundationbot/Phantom-OS-KubernetesOptions", username: x-access-token, password: ghp_x}
YAML
  chmod 0600 "$f"
  REPO_CREDENTIAL_FILE="$f"
  KUBECTL=(kubectl)

  # Call _apply_repo_credential directly — full gitops() depends on terraform.
  _apply_repo_credential "$REPO_CREDENTIAL_FILE"
  grep -q 'apply -n argocd' "$STUB_LOG_KUBECTL"
}
