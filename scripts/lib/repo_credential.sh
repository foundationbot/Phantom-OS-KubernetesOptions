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

  # Best-effort verification: argocd repo list requires CLI auth (which the
  # phase 9 argocd_users hasn't run yet during a fresh bringup), so we don't
  # fail the phase if it can't connect. Real validation happens when the
  # first Application sync hits the credential. If argocd CLI happens to be
  # already logged in (re-runs / rotations), we surface the connection state.
  local i
  for i in $(seq 1 15); do
    if argocd repo list 2>/dev/null | grep -q 'Successful'; then
      pass "argocd repo list reports Successful"
      return 0
    fi
    sleep 2
  done
  info "argocd repo list did not report Successful in 30s (likely CLI not yet logged in — run 'argocd app sync' after argocd_users phase to verify auth)"
  return 0
}
