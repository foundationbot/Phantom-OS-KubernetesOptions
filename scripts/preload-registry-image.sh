#!/usr/bin/env bash
# preload-registry-image.sh
#
# Preload the in-cluster registry's own image (registry:2, or whatever
# tag manifests/base/registry/registry.yaml pins) into k0s's containerd
# k8s.io namespace, so the k0s-registry pod can start on a host that has
# NO local image bundle.
#
# WHY (FIR-465): scripts/configure-k0s-containerd-mirror.sh routes
# docker.io/* through the in-cluster registry at localhost:5443. On a
# fresh host without the phantomos-k0s-images bundle, the k0s-registry
# pod IS that registry — but it isn't up yet, so containerd cannot pull
# its own `registry:2` image through the mirror it serves. Chicken-and-
# egg: the pod hangs in ContainerCreating forever. Observed on
# mk11000020.
#
# Online this is usually masked because containerd's hosts.toml lists
# DockerHub *first* and falls through to the local registry only on
# failure — but the failure mode bites whenever DockerHub is slow/
# unreachable, the host is freshly imaged, or the resolve order is
# perturbed. Preloading the image directly removes the dependency
# entirely: the kubelet finds registry:2 already present (imagePullPolicy
# is IfNotPresent) and starts the pod without any pull.
#
# The pull is done via the host's docker daemon, which does NOT use
# k0s's containerd mirror (separate daemon, separate config), so it goes
# straight to DockerHub and cannot deadlock on the registry pod. The
# image is then handed to containerd with `docker save | k0s ctr import`.
#
# Idempotent: a no-op when the image is already in containerd. Degrades
# gracefully (skip with a clear message, exit 0) when docker is missing
# or the pull fails — bootstrap continues; the operator can preload
# manually or wait for the online DockerHub fallthrough.
#
# Usage:   sudo bash scripts/preload-registry-image.sh
#
# Env overrides:
#   REGISTRY_MANIFEST  path to registry.yaml (default: repo manifest)
#   REGISTRY_IMAGE     explicit image ref, bypassing manifest parsing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_MANIFEST="${REGISTRY_MANIFEST:-${REPO_ROOT}/manifests/base/registry/registry.yaml}"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }

# Resolve the registry image ref. Prefer an explicit override; otherwise
# read the `image:` line under the registry container in the manifest so
# we preload the EXACT tag the pod will request (never a hardcoded one).
resolve_image() {
  if [ -n "${REGISTRY_IMAGE:-}" ]; then
    printf '%s' "$REGISTRY_IMAGE"
    return 0
  fi
  if [ ! -r "$REGISTRY_MANIFEST" ]; then
    return 1
  fi
  # First `image:` value in the manifest (the registry container).
  grep -oE '^[[:space:]]*image:[[:space:]]*"?[^"[:space:]]+"?' "$REGISTRY_MANIFEST" \
    | head -1 \
    | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/"//g'
}

# True when the ref is already present in containerd's k8s.io namespace.
# containerd normalizes short refs (registry:2) to a fully-qualified name
# (docker.io/library/registry:2), so match on the repo:tag suffix rather
# than an exact string compare.
image_in_containerd() {
  local ref="$1" pat
  # Strip any registry host prefix down to the repo:tag for matching.
  pat="${ref##*/}"   # e.g. registry:2
  k0s ctr -n k8s.io images list -q 2>/dev/null | grep -qE "(^|/)${pat//./\\.}\$"
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (try: sudo bash $0)" >&2
    exit 2
  fi

  if ! command -v k0s >/dev/null 2>&1; then
    warn "k0s not on PATH — cannot preload registry image; skipping"
    exit 0
  fi

  local image
  if ! image="$(resolve_image)" || [ -z "$image" ]; then
    warn "could not resolve registry image from ${REGISTRY_MANIFEST} (set REGISTRY_IMAGE=); skipping"
    exit 0
  fi
  info "registry image: ${image}"

  if image_in_containerd "$image"; then
    ok "${image} already present in containerd (k8s.io) — nothing to do"
    exit 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not installed — cannot preload ${image} without the mirror; skipping"
    info "the pod will still start online via the DockerHub fallthrough, or"
    info "preload manually: docker pull ${image} && docker save ${image} | k0s ctr -n k8s.io images import -"
    exit 0
  fi

  info "pulling ${image} via docker (bypasses the containerd mirror)..."
  if ! docker pull "$image" >/dev/null 2>&1; then
    warn "docker pull ${image} failed (offline?) — skipping preload"
    info "the k0s-registry pod may hang in ContainerCreating until ${image} is available;"
    info "once online, retry: sudo bash $0"
    exit 0
  fi

  info "importing ${image} into containerd (k8s.io namespace)..."
  if docker save "$image" | k0s ctr -n k8s.io images import -; then
    ok "${image} imported into containerd — k0s-registry can now start without the mirror"
    exit 0
  else
    warn "import of ${image} into containerd failed — skipping"
    exit 0
  fi
}

main "$@"
