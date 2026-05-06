# scripts/lib/etcd_encryption.sh — generate / install k0s EncryptionConfiguration.
# Sourced by bootstrap-robot.sh during deps phase, before k0s starts so all
# Secrets land encrypted on first write. Unit-tested via bats.

ETCD_ENCRYPTION_CONFIG_PATH="${ETCD_ENCRYPTION_CONFIG_PATH:-/var/lib/k0s/pki/encryption-config.yaml}"
ETCD_ENCRYPTION_KEY_BACKUP_PATH="${ETCD_ENCRYPTION_KEY_BACKUP_PATH:-/etc/phantomos/etcd-encryption-key.bak}"
ETCD_ENCRYPTION_KEY_NAME="${ETCD_ENCRYPTION_KEY_NAME:-phantomos-v1}"

_ensure_etcd_encryption_config() {
  if [ -f "$ETCD_ENCRYPTION_CONFIG_PATH" ]; then
    info "etcd encryption config already present at $ETCD_ENCRYPTION_CONFIG_PATH"
    return 0
  fi

  mkdir -p "$(dirname "$ETCD_ENCRYPTION_CONFIG_PATH")" || {
    fail "cannot create $(dirname "$ETCD_ENCRYPTION_CONFIG_PATH")"; return 1
  }

  local key
  key=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

  umask 077
  cat > "$ETCD_ENCRYPTION_CONFIG_PATH" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: $ETCD_ENCRYPTION_KEY_NAME
              secret: $key
      - identity: {}
EOF
  # kube-apiserver runs as user 'kube-apiserver' on k0s and reads this file
  # at startup. mode 0600 root:root would EACCES the apiserver. Match the
  # k0s pki convention (compare /var/lib/k0s/pki/apiserver-kubelet-client.key):
  # owner kube-apiserver:root, mode 0640. Fall back to mode 0600 in test
  # environments where the user does not exist.
  if id kube-apiserver >/dev/null 2>&1; then
    chown kube-apiserver:root "$ETCD_ENCRYPTION_CONFIG_PATH"
    chmod 0640 "$ETCD_ENCRYPTION_CONFIG_PATH"
  else
    chmod 0600 "$ETCD_ENCRYPTION_CONFIG_PATH"
  fi

  mkdir -p "$(dirname "$ETCD_ENCRYPTION_KEY_BACKUP_PATH")"
  printf '%s\n' "$key" > "$ETCD_ENCRYPTION_KEY_BACKUP_PATH"
  chmod 0600 "$ETCD_ENCRYPTION_KEY_BACKUP_PATH"

  pass "generated k0s etcd encryption config + backup key"
  return 0
}
