# tests/bash/partial_phases.bats
load 'helpers/load'
setup() { setup_common; }

@test "--gitops-repo-credential-only runs only the credential apply step" {
  # Use --dry-run so it doesn't touch the system; we just verify selected phases.
  run bash "$REPO_ROOT/scripts/bootstrap-robot.sh" --dry-run \
      --gitops-repo-credential-only --repo-credential-file /dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'apply repo credential'
  ! echo "$output" | grep -qE '\bphase 1: preflight\b'
  ! echo "$output" | grep -qE '\bphase 2: deps\b'
}

@test "--gitops-rbac-only runs only the RBAC overlay applies" {
  run bash "$REPO_ROOT/scripts/bootstrap-robot.sh" --dry-run --gitops-rbac-only
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'apply argocd-secret-rbac'
  echo "$output" | grep -qE 'apply argocd-rbac'
  ! echo "$output" | grep -qE '\bphase 2: deps\b'
}
