# tests/bash/smoke.bats
load 'helpers/load'
setup() { setup_common; }

@test "stub kubectl logs args and exits 0" {
  run kubectl get pods -n default
  [ "$status" -eq 0 ]
  grep -q 'get pods -n default' "$STUB_LOG_KUBECTL"
}

@test "stub kubectl honors STUB_KUBECTL_FAIL" {
  STUB_KUBECTL_FAIL=1 run kubectl get pods
  [ "$status" -ne 0 ]
}

@test "stub htpasswd emits bcrypt-shaped string" {
  run htpasswd -nbBC 10 "" "hunter2"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^:\$2y\$10\$ ]]
}
