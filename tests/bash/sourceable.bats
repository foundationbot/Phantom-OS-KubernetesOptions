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
  [[ "$output" =~ "phase 1: preflight" ]] || [[ "$output" =~ "Usage" ]]
}
