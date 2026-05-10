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
REGISTRY_DEPLOYMENT="${REGISTRY_DEPLOYMENT:-k0s-registry}"
REGISTRY_WAIT_SECS="${REGISTRY_WAIT_SECS:-120}"
CONTAINERD_HOSTS_DIR="${CONTAINERD_HOSTS_DIR:-/etc/k0s/containerd.d/hosts}"
CONTAINERD_CONFIG="${CONTAINERD_CONFIG:-/etc/k0s/containerd.toml}"
SMOKE_TAG="${SMOKE_TAG:-${REGISTRY_HOST}/validate/hello-world:smoke}"

pass_count=0
fail_count=0
skip_count=0
warn_count=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s — %s\n' "$1" "$2"; skip_count=$((skip_count + 1)); }
# warn: informational, does NOT contribute to the exit code. Used by the
# host-config-vs-bundle drift check, where pulling from upstream is a
# legitimate operator choice (host-config is the authoritative source of
# truth per RFC 0005), so an entry the bundle doesn't satisfy is a hint
# and not a failure.
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; warn_count=$((warn_count + 1)); }

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

# Wait for the in-cluster registry Deployment to become Available before
# we run the dependent tests (T03 HTTP reachability, T04 docker push,
# T07 pod Running, T12 k0s ctr pull, T13 prime + pull). Useful right
# after a fresh bootstrap where ArgoCD may still be syncing manifests
# when validate runs — without this wait the operator gets a wall of
# false negatives that just need a re-run a minute later.
#
# Soft: kubectl unavailable -> no-op (existing T05 skip will fire);
# namespace missing -> note + continue (T06 will fail clearly);
# Deployment missing -> note + continue (T07 will fail clearly);
# Available timeout -> note + continue (T07 will fail and other tests
# will surface the underlying problem). Never fails the validator on
# its own; it just gives the cluster a deterministic head-start.
wait_for_registry() {
  [ -z "$KUBECTL" ] && return 0
  if ! kc get ns "$REGISTRY_NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi
  if ! kc -n "$REGISTRY_NAMESPACE" get deploy "$REGISTRY_DEPLOYMENT" \
       >/dev/null 2>&1; then
    return 0
  fi
  printf '\033[2m  · waiting up to %ss for deploy/%s in %s to become Available...\033[0m\n' \
    "$REGISTRY_WAIT_SECS" "$REGISTRY_DEPLOYMENT" "$REGISTRY_NAMESPACE"
  if kc -n "$REGISTRY_NAMESPACE" wait \
       --for=condition=Available \
       "deploy/$REGISTRY_DEPLOYMENT" \
       "--timeout=${REGISTRY_WAIT_SECS}s" >/dev/null 2>&1; then
    printf '\033[2m  · deploy/%s Available\033[0m\n' "$REGISTRY_DEPLOYMENT"
  else
    printf '\033[33m  · deploy/%s did not become Available within %ss — continuing; failing tests below will pinpoint why\033[0m\n' \
      "$REGISTRY_DEPLOYMENT" "$REGISTRY_WAIT_SECS"
  fi
}
wait_for_registry

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

# --- host-config images vs. bundled tarballs (RFC 0005 phase 5) -----------
#
# Cross-check every entry in /etc/phantomos/host-config.yaml's images:
# block against what's actually in /var/lib/k0s/images/. The intent is to
# surface "host-config says X, but X isn't on disk" cases so the operator
# can either fix the host-config or accept that X will be pulled from
# upstream at first use.
#
# Two resolution paths:
#
#  1. Bundle manifest sidecar (.phantomos-image-bundle.yaml) is the
#     authoritative `container -> ref -> tarball` mapping written at .deb
#     build time. When present, look up each canonical container from
#     host-config and compare the bundle's ref to the host-config ref. If
#     they match the tarball is on disk and named in the bundle; if they
#     differ the operator has overridden — pull-from-upstream is fine,
#     but worth flagging (RFC 0005's "Validation cross-checks").
#
#  2. Tarball-scan fallback for older .debs without the bundle manifest:
#     for each ref, scan every *.tar under /var/lib/k0s/images/ for a
#     manifest.json containing that ref in RepoTags. Slower (a few
#     seconds for a full scan) and brittle on swap-repo cases (an
#     operator-supplied positronic-control image may appear under any
#     repo) but works retroactively on .debs that predate Phase 1.
#
# Outcome: emit OK on hit, WARN on miss. Never FAIL — host-config is the
# source of truth, the operator may legitimately pin upstream refs, and
# this validator's exit code only reflects hard failures of the local
# registry/mirror plumbing.

section "host-config images vs. bundled tarballs (T14)"

HOST_CONFIG_PATH="${HOST_CONFIG_PATH:-/etc/phantomos/host-config.yaml}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/k0s/images}"
BUNDLE_MANIFEST="${BUNDLE_MANIFEST:-${IMAGES_DIR}/.phantomos-image-bundle.yaml}"

if ! have python3; then
  skip "T14 host-config images cross-check" "python3 not installed (required to parse YAML/manifest.json)"
elif [ ! -r "$HOST_CONFIG_PATH" ]; then
  skip "T14 host-config images cross-check" "${HOST_CONFIG_PATH} missing or unreadable"
elif [ ! -d "$IMAGES_DIR" ]; then
  skip "T14 host-config images cross-check" "${IMAGES_DIR} missing"
else
  # Extract the host-config images block as `container<TAB>ref` lines.
  # Empty output means no images: block — skip cleanly.
  hc_images_tsv=$(python3 - "$HOST_CONFIG_PATH" <<'PYEOF' 2>/dev/null || true
import sys
try:
    import yaml
except ModuleNotFoundError:
    sys.exit(0)
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
imgs = cfg.get("images") or {}
if not isinstance(imgs, dict):
    sys.exit(0)
for cname, spec in imgs.items():
    if not isinstance(spec, dict):
        continue
    img = spec.get("image")
    if isinstance(img, str) and img and not img.startswith("REPLACE-WITH-"):
        print(f"{cname}\t{img}")
PYEOF
)

  if [ -z "$hc_images_tsv" ]; then
    skip "T14 host-config images cross-check" "no images: entries in ${HOST_CONFIG_PATH}"
  else
    # Build the bundle's container -> (ref, tarball) map if available.
    # An empty result here means "no bundle, fall through to tarball scan."
    bundle_tsv=""
    if [ -r "$BUNDLE_MANIFEST" ]; then
      bundle_tsv=$(python3 - "$BUNDLE_MANIFEST" <<'PYEOF' 2>/dev/null || true
import sys
try:
    import yaml
except ModuleNotFoundError:
    sys.exit(0)
try:
    with open(sys.argv[1]) as f:
        b = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
if not isinstance(b, dict):
    sys.exit(0)
for entry in (b.get("bundle") or []):
    if not isinstance(entry, dict):
        continue
    c = entry.get("container"); r = entry.get("ref"); t = entry.get("tarball") or ""
    if isinstance(c, str) and isinstance(r, str) and r:
        print(f"{c}\t{r}\t{t}")
PYEOF
)
    fi

    # If the bundle has any entries, prefer it as the lookup. Otherwise
    # scan tarballs directly.
    if [ -n "$bundle_tsv" ]; then
      while IFS=$'\t' read -r cname hc_ref; do
        [ -z "$cname" ] && continue
        bundle_match=$(printf '%s\n' "$bundle_tsv" | awk -F'\t' -v c="$cname" '$1 == c { print; exit }')
        if [ -z "$bundle_match" ]; then
          warn "T14 ${cname}=${hc_ref}: no entry in bundle manifest — will pull from upstream"
          continue
        fi
        b_ref=$(printf '%s' "$bundle_match" | awk -F'\t' '{print $2}')
        b_tar=$(printf '%s' "$bundle_match" | awk -F'\t' '{print $3}')
        if [ "$b_ref" = "$hc_ref" ]; then
          pass "T14 ${cname}=${hc_ref}: bundled in ${IMAGES_DIR}/${b_tar}"
        else
          warn "T14 ${cname}=${hc_ref}: bundle has ${b_ref} (tarball ${b_tar}) — will pull from upstream"
        fi
      done <<< "$hc_images_tsv"
    else
      # Fallback: scan every *.tar's manifest.json RepoTags. Slow, but
      # the only path for .debs that predate the bundle manifest.
      tar_count=$(find "$IMAGES_DIR" -maxdepth 1 -type f -name '*.tar' 2>/dev/null | wc -l)
      if [ "$tar_count" -eq 0 ]; then
        while IFS=$'\t' read -r cname hc_ref; do
          [ -z "$cname" ] && continue
          warn "T14 ${cname}=${hc_ref}: no *.tar files in ${IMAGES_DIR} — will pull from upstream"
        done <<< "$hc_images_tsv"
      else
        # Build a single ref -> tarball map by scanning each tar once.
        # Output: ref<TAB>basename.tar lines, accumulated into a temp
        # variable. Errors during extraction (e.g. truncated tarball)
        # are swallowed — the per-tarball scan logs warnings inline.
        repo_tags_tsv=""
        while IFS= read -r tar_path; do
          [ -z "$tar_path" ] && continue
          tar_base=$(basename "$tar_path")
          tags=$(tar -xOf "$tar_path" manifest.json 2>/dev/null \
            | python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in data:
    for t in (m.get("RepoTags") or []):
        print(t)
' 2>/dev/null || true)
          while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            repo_tags_tsv+="${tag}"$'\t'"${tar_base}"$'\n'
          done <<< "$tags"
        done < <(find "$IMAGES_DIR" -maxdepth 1 -type f -name '*.tar' 2>/dev/null)

        while IFS=$'\t' read -r cname hc_ref; do
          [ -z "$cname" ] && continue
          match=$(printf '%s' "$repo_tags_tsv" | awk -F'\t' -v r="$hc_ref" '$1 == r { print $2; exit }')
          if [ -n "$match" ]; then
            pass "T14 ${cname}=${hc_ref}: bundled in ${IMAGES_DIR}/${match}"
          else
            warn "T14 ${cname}=${hc_ref} not bundled — will pull from upstream"
          fi
        done <<< "$hc_images_tsv"
      fi
    fi
  fi
fi

# --- Summary --------------------------------------------------------------

section "Summary"
printf '  %d passed, %d failed, %d skipped, %d warned\n' \
  "$pass_count" "$fail_count" "$skip_count" "$warn_count"

exit "$fail_count"
