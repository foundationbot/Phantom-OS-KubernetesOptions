# scripts/lib/argocd_users.sh — set ArgoCD per-account passwords by patching
# argocd-secret. Sourced by bootstrap-robot.sh; unit-tested via bats with a
# stubbed kubectl/htpasswd. Depends on bash-level helpers (pass/fail/info)
# and KUBECTL[] from the caller.

# _argocd_set_account_password <account> <plaintext>
#   Bcrypts the plaintext via htpasswd and patches argocd-secret with the
#   per-account keys (admin uses the legacy unprefixed keys; everyone else
#   uses accounts.<name>.password / .passwordMtime).
_argocd_set_account_password() {
  local account="${1:-}" pw="${2:-}"
  if [ -z "$account" ]; then
    fail "_argocd_set_account_password: account name required"
    return 2
  fi
  if [ -z "$pw" ]; then
    fail "_argocd_set_account_password: password required for '$account'"
    return 2
  fi

  if ! command -v htpasswd >/dev/null 2>&1; then
    info "installing apache2-utils (for htpasswd)"
    apt-get install -y apache2-utils >/dev/null 2>&1 || true
  fi
  if ! command -v htpasswd >/dev/null 2>&1; then
    fail "htpasswd unavailable — install apache2-utils manually"
    return 3
  fi

  local hash mtime password_key mtime_key
  hash=$(htpasswd -nbBC 10 "" "$pw" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
  mtime=$(date +%FT%T%Z)

  case "$account" in
    admin)
      password_key="admin.password"
      mtime_key="admin.passwordMtime"
      ;;
    *)
      password_key="accounts.${account}.password"
      mtime_key="accounts.${account}.passwordMtime"
      ;;
  esac

  if "${KUBECTL[@]}" -n argocd patch secret argocd-secret --type merge \
       -p "{\"stringData\":{\"$password_key\":\"$hash\",\"$mtime_key\":\"$mtime\"}}" \
       >/dev/null; then
    pass "argocd account '$account' password updated"
    return 0
  fi
  fail "could not patch argocd-secret for account '$account'"
  return 1
}
