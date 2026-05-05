# tests/bash/etcd_encryption.bats
load 'helpers/load'
setup() {
  setup_common
  source "$REPO_ROOT/scripts/lib/etcd_encryption.sh" 2>/dev/null || true
  pass()  { :; }; fail()  { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }; info()  { :; }
  FAIL=0
  ETCD_ENCRYPTION_CONFIG_PATH="$BATS_TEST_TMPDIR/encryption-config.yaml"
  ETCD_ENCRYPTION_KEY_BACKUP_PATH="$BATS_TEST_TMPDIR/etcd-encryption-key.bak"
}

@test "_ensure_etcd_encryption_config generates a fresh key on first run" {
  run _ensure_etcd_encryption_config
  [ "$status" -eq 0 ]
  [ -f "$ETCD_ENCRYPTION_CONFIG_PATH" ]
  grep -q 'kind: EncryptionConfiguration' "$ETCD_ENCRYPTION_CONFIG_PATH"
  grep -qE 'aescbc:' "$ETCD_ENCRYPTION_CONFIG_PATH"
  # 32-byte base64 key = ~44 chars
  grep -qE 'secret:\s+[A-Za-z0-9+/]{40,}=*' "$ETCD_ENCRYPTION_CONFIG_PATH"
}

@test "_ensure_etcd_encryption_config writes file with mode 0600" {
  _ensure_etcd_encryption_config
  mode=$(stat -c '%a' "$ETCD_ENCRYPTION_CONFIG_PATH")
  [ "$mode" = "600" ]
}

@test "_ensure_etcd_encryption_config writes a backup key" {
  _ensure_etcd_encryption_config
  [ -f "$ETCD_ENCRYPTION_KEY_BACKUP_PATH" ]
  mode=$(stat -c '%a' "$ETCD_ENCRYPTION_KEY_BACKUP_PATH")
  [ "$mode" = "600" ]
}

@test "_ensure_etcd_encryption_config is idempotent — does not regenerate the key" {
  _ensure_etcd_encryption_config
  before=$(sha256sum "$ETCD_ENCRYPTION_CONFIG_PATH" | awk '{print $1}')
  _ensure_etcd_encryption_config
  after=$(sha256sum "$ETCD_ENCRYPTION_CONFIG_PATH" | awk '{print $1}')
  [ "$before" = "$after" ]
}
