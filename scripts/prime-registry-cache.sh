#!/usr/bin/env bash
# prime-registry-cache.sh
#
# Pre-populates the local registry at localhost:5000 by pulling images
# from upstream (DockerHub) and pushing them into the local registry
# under their docker.io-equivalent paths.
#
# Why: the registry's pull-through cache only fills when containerd
# requests an image. Before first pull (or if DockerHub is unreachable
# when a new pod wants an image for the first time), the cache is empty
# for that image. Priming avoids that gap.
#
# This uses direct docker push (not the containerd proxy path) so it
# works even before the containerd mirror config is installed.
#
# Usage:
#   prime-registry-cache.sh <image> [<image>...]
#   prime-registry-cache.sh --from-file <path>         # one image per line
#   prime-registry-cache.sh --from-cluster              # discover via kubectl
#   prime-registry-cache.sh --from-manifests <dir>      # grep image: out of YAML
#
# Examples:
#   # Prime the two argus services used most often
#   ./prime-registry-cache.sh foundationbot/argus.auth:qa foundationbot/argus.gateway:qa
#
#   # Prime everything the running cluster uses
#   ./prime-registry-cache.sh --from-cluster
#
#   # Prime everything this repo references
#   ./prime-registry-cache.sh --from-manifests manifests/
#
# Prerequisites:
#   - docker running, logged in to DockerHub for private foundationbot/* images
#     (docker login)
#   - registry:2 reachable at ${REGISTRY_HOST} (default localhost:5000)
#   - /etc/docker/daemon.json lists ${REGISTRY_HOST} as an insecure-registry
#     (configure-k0s-containerd-mirror.sh handles this)

set -u -o pipefail

REGISTRY_HOST="${REGISTRY_HOST:-localhost:5000}"

ok_count=0
fail_count=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1";   ok_count=$((ok_count + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail_count=$((fail_count + 1)); }

# Normalize an image ref into the path the local registry should serve it
# under, so containerd's mirror finds it when pulling docker.io/<x>.
#
#   mongo:7                         -> localhost:5000/library/mongo:7
#   foundationbot/argus.auth:qa     -> localhost:5000/foundationbot/argus.auth:qa
#   docker.io/library/alpine:3.19   -> localhost:5000/library/alpine:3.19
#   localhost:5000/foo:bar          -> localhost:5000/foo:bar     (unchanged)
normalize_target() {
  local img="$1"

  if [[ "$img" == "${REGISTRY_HOST}/"* ]]; then
    printf '%s' "$img"; return
  fi

  img="${img#docker.io/}"
  img="${img#registry-1.docker.io/}"
  img="${img#index.docker.io/}"

  local repo="${img%:*}"
  local tag=""
  if [[ "$img" == *:* ]]; then
    tag=":${img##*:}"
  fi

  if [[ "$repo" != */* ]]; then
    printf '%s/library/%s%s' "$REGISTRY_HOST" "$repo" "$tag"
  else
    printf '%s/%s%s' "$REGISTRY_HOST" "$repo" "$tag"
  fi
}

prime_one() {
  local src="$1"
  local target
  target="$(normalize_target "$src")"

  # Already a localhost:5000/* ref? Nothing to pull from upstream.
  if [[ "$src" == "${REGISTRY_HOST}/"* ]]; then
    fail "${src} — already points at local registry; nothing to prime"
    return
  fi

  if ! docker pull -q "$src" >/dev/null 2>&1; then
    fail "${src} — docker pull failed (auth? tag missing upstream?)"
    return
  fi

  if ! docker tag "$src" "$target" 2>/dev/null; then
    fail "${src} -> ${target} — docker tag failed"
    return
  fi

  if ! docker push -q "$target" >/dev/null 2>&1; then
    fail "${target} — docker push failed (registry reachable? insecure-registries configured?)"
    return
  fi

  ok "${src}  ->  ${target}"
}

collect_from_cluster() {
  local kubectl_cmd=""
  if command -v kubectl >/dev/null 2>&1; then
    kubectl_cmd="kubectl"
  elif command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
    kubectl_cmd="k0s kubectl"
  else
    echo "error: --from-cluster requires kubectl or k0s" >&2
    exit 2
  fi
  # List every container image in every namespace, deduped. Filters out
  # localhost:5000/* entries (no point re-priming) and empty strings.
  $kubectl_cmd get pods --all-namespaces \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null \
    | grep -v "^${REGISTRY_HOST}/" \
    | grep -v '^$' \
    | sort -u
}

collect_from_manifests() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "error: --from-manifests: not a directory: $dir" >&2
    exit 2
  fi
  # Grep image: lines, strip quotes and leading whitespace.
  grep -rhE '^\s*image:\s*' "$dir" \
    | sed -E 's/^\s*image:\s*//; s/^["'\'']//; s/["'\'']$//' \
    | grep -v "^${REGISTRY_HOST}/" \
    | grep -v '^$' \
    | sort -u
}

if [ "$#" -eq 0 ]; then
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -40
  exit 2
fi

images=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-file)
      [ -r "${2:-}" ] || { echo "error: --from-file needs a readable path" >&2; exit 2; }
      while IFS= read -r line; do
        line="${line%%#*}"              # strip comments
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] && images+=("$line")
      done < "$2"
      shift 2
      ;;
    --from-cluster)
      while IFS= read -r line; do
        [ -n "$line" ] && images+=("$line")
      done < <(collect_from_cluster)
      shift
      ;;
    --from-manifests)
      [ -d "${2:-}" ] || { echo "error: --from-manifests needs a directory" >&2; exit 2; }
      while IFS= read -r line; do
        [ -n "$line" ] && images+=("$line")
      done < <(collect_from_manifests "$2")
      shift 2
      ;;
    --*)
      echo "error: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      images+=("$1")
      shift
      ;;
  esac
done

if [ "${#images[@]}" -eq 0 ]; then
  echo "nothing to prime" >&2
  exit 0
fi

printf 'Priming %d image(s) into %s\n\n' "${#images[@]}" "$REGISTRY_HOST"
for img in "${images[@]}"; do
  prime_one "$img"
done

printf '\n  %d primed, %d failed\n' "$ok_count" "$fail_count"
exit "$fail_count"
