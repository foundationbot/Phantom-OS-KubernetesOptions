#!/usr/bin/env bash
# validate-local-registry.sh
#
# Verifies that the local registry + containerd hosts-config is correctly
# installed on this host (matching what configure-k0s-containerd-mirror.sh
# sets up).
#
# Each check prints PASS / FAIL / SKIP. Exit code = number of FAILs.
# SKIPs are not failures — they happen when a prerequisite (e.g. k0s)
# is absent. Run on the robot after bootstrap; safe to run repeatedly.

set -u -o pipefail

REGISTRY_HOST="${REGISTRY_HOST:-localhost:5443}"
REGISTRY_STORAGE="${REGISTRY_STORAGE:-/var/lib/registry}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry}"
CONTAINERD_HOSTS_DIR="${CONTAINERD_HOSTS_DIR:-/etc/k0s/containerd.d/hosts}"
CONTAINERD_CONFIG="${CONTAINERD_CONFIG:-/etc/k0s/containerd.toml}"
SMOKE_TAG="${SMOKE_TAG:-${REGISTRY_HOST}/validate/hello-world:smoke}"

pass_count=0
fail_count=0
skip_count=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s — %s\n' "$1" "$2"; skip_count=$((skip_count + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Resolve a kubectl command. Standalone kubectl wins; fall back to
# `k0s kubectl` (k0s vendors kubectl) so the validator works on robots
# that have only the k0s binary installed.
KUBECTL=""
if have kubectl; then
  KUBECTL="kubectl"
elif have k0s && k0s kubectl version --client >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
fi
kc() { eval "$KUBECTL" "\"\$@\""; }

# --- Docker (host push path) -----------------------------------------------

section "Docker (host-side push path)"

if ! have docker; then
  skip "T01 docker-cli present"            "docker not installed"
  skip "T02 daemon.json insecure-registry" "docker not installed"
  skip "T03 registry HTTP endpoint"        "docker not installed"
  skip "T04 smoke push to registry"        "docker not installed"
else
  pass "T01 docker-cli present"

  daemon_json="/etc/docker/daemon.json"
  if [ -r "$daemon_json" ] && grep -q "\"${REGISTRY_HOST}\"" "$daemon_json"; then
    pass "T02 daemon.json lists ${REGISTRY_HOST} as insecure-registry"
  else
    fail "T02 daemon.json should list ${REGISTRY_HOST} in insecure-registries (${daemon_json})"
  fi

  if curl -fs -o /dev/null --max-time 5 "http://${REGISTRY_HOST}/v2/" 2>/dev/null; then
    pass "T03 registry HTTP endpoint reachable at http://${REGISTRY_HOST}/v2/"
  else
    fail "T03 registry HTTP endpoint not reachable (GET http://${REGISTRY_HOST}/v2/)"
  fi

  if docker pull -q hello-world >/dev/null 2>&1 \
    && docker tag hello-world "$SMOKE_TAG" \
    && docker push -q "$SMOKE_TAG" >/dev/null 2>&1; then
    pass "T04 docker push ${SMOKE_TAG} succeeded"
  else
    fail "T04 docker push ${SMOKE_TAG} failed"
  fi
fi

# --- Kubernetes / registry pod ---------------------------------------------

section "Kubernetes registry pod"

if [ -z "$KUBECTL" ]; then
  skip "T05 kubectl resolvable"           "neither kubectl nor 'k0s kubectl' available"
  skip "T06 registry namespace exists"    "kubectl unavailable"
  skip "T07 registry pod Running"         "kubectl unavailable"
  skip "T08 registry storage dir exists"  "kubectl unavailable"
else
  pass "T05 kubectl resolvable (using: ${KUBECTL})"

  if kc get ns "$REGISTRY_NAMESPACE" >/dev/null 2>&1; then
    pass "T06 namespace ${REGISTRY_NAMESPACE} exists"
  else
    fail "T06 namespace ${REGISTRY_NAMESPACE} missing"
  fi

  if kc -n "$REGISTRY_NAMESPACE" get pod -l app=k0s-registry \
       -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running; then
    pass "T07 registry pod Running in ${REGISTRY_NAMESPACE}"
  else
    fail "T07 no Running pod with label app=k0s-registry in ${REGISTRY_NAMESPACE}"
  fi

  if [ -d "$REGISTRY_STORAGE" ]; then
    pass "T08 registry storage dir exists (${REGISTRY_STORAGE})"
  else
    fail "T08 registry storage dir missing (${REGISTRY_STORAGE})"
  fi
fi

# --- containerd mirror config ---------------------------------------------

section "containerd mirror config"

if ! have k0s; then
  skip "T09 k0s installed"                "k0s not installed"
  skip "T10 hosts.toml present + correct" "k0s not installed"
  skip "T11 containerd config_path wired" "k0s not installed"
  skip "T12 k0s pulls ${SMOKE_TAG}"       "k0s not installed"
  skip "T13 prime alpine + k0s ctr pull"  "k0s not installed"
else
  pass "T09 k0s installed"

  hosts_toml="${CONTAINERD_HOSTS_DIR}/docker.io/hosts.toml"
  if [ -r "$hosts_toml" ] && grep -q "host.\"http://${REGISTRY_HOST}\"" "$hosts_toml"; then
    pass "T10 ${hosts_toml} present and references ${REGISTRY_HOST}"
  else
    fail "T10 ${hosts_toml} missing or does not reference ${REGISTRY_HOST}"
  fi

  # T11: config_path can be wired two ways. Either (a) directly in the
  # main containerd.toml under [plugins."io.containerd.grpc.v1.cri".registry],
  # or (b) via an `imports` directive in containerd.toml that pulls in a
  # drop-in TOML under /etc/k0s/containerd.d/ which contains the config_path.
  config_path_re="config_path *= *\"${CONTAINERD_HOSTS_DIR}\""
  t11_main_direct=false
  t11_imports=false
  t11_dropin=false
  if [ -r "$CONTAINERD_CONFIG" ]; then
    if grep -Eq "$config_path_re" "$CONTAINERD_CONFIG"; then t11_main_direct=true; fi
    if grep -Eq '^imports *=' "$CONTAINERD_CONFIG"; then t11_imports=true; fi
  fi
  if compgen -G "${CONTAINERD_IMPORT_DIR:-/etc/k0s/containerd.d}/*.toml" >/dev/null 2>&1 \
    && grep -Esq "$config_path_re" "${CONTAINERD_IMPORT_DIR:-/etc/k0s/containerd.d}"/*.toml; then
    t11_dropin=true
  fi
  if $t11_main_direct; then
    pass "T11 config_path set directly in ${CONTAINERD_CONFIG}"
  elif $t11_imports && $t11_dropin; then
    pass "T11 config_path wired via imports + drop-in"
  else
    fail "T11 config_path not wired (need either direct setting in ${CONTAINERD_CONFIG} or imports + drop-in pair)"
  fi

  if sudo -n true 2>/dev/null; then
    if sudo k0s ctr -n k8s.io images pull --plain-http "$SMOKE_TAG" >/dev/null 2>&1; then
      pass "T12 k0s ctr pulled ${SMOKE_TAG}"
    else
      fail "T12 k0s ctr pull ${SMOKE_TAG} failed"
    fi

    # T13: end-to-end prime + mirror chain. Push library/alpine:3.19 to the
    # local registry, then ask k0s containerd to pull docker.io/library/alpine:3.19.
    # If the mirror config is right, the pull succeeds via the local registry;
    # if the mirror is broken but upstream is reachable, it still succeeds via
    # fallthrough — either way, "k0s ctr pull works after prime" is the property
    # we care about. Skips if docker isn't available (priming requires it).
    if have docker; then
      if docker pull -q alpine:3.19 >/dev/null 2>&1 \
        && docker tag alpine:3.19 "${REGISTRY_HOST}/library/alpine:3.19" \
        && docker push -q "${REGISTRY_HOST}/library/alpine:3.19" >/dev/null 2>&1; then
        if sudo k0s ctr -n k8s.io images pull docker.io/library/alpine:3.19 >/dev/null 2>&1; then
          pass "T13 prime alpine:3.19 -> local registry, then k0s ctr pull docker.io/library/alpine:3.19"
        else
          fail "T13 alpine pushed to local but k0s ctr pull docker.io/library/alpine:3.19 failed"
        fi
      else
        fail "T13 could not push alpine:3.19 to local registry"
      fi
    else
      skip "T13 prime alpine + k0s ctr pull" "docker not installed (needed for prime push)"
    fi
  else
    skip "T12 k0s pulls ${SMOKE_TAG}"      "passwordless sudo unavailable"
    skip "T13 prime alpine + k0s ctr pull" "passwordless sudo unavailable"
  fi
fi

# --- Summary --------------------------------------------------------------

section "Summary"
printf '  %d passed, %d failed, %d skipped\n' "$pass_count" "$fail_count" "$skip_count"

exit "$fail_count"
