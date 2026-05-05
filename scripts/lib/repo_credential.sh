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
