#!/usr/bin/env bash
# prune-registry-tags.sh — list/remove tags via the local registry's HTTP
# API and optionally reclaim disk via `registry garbage-collect`.
#
# Uses the standard Distribution v2 manifest-delete endpoint
# (DELETE /v2/<repo>/manifests/<digest>), which requires
# REGISTRY_STORAGE_DELETE_ENABLED=true on the registry Deployment
# (set in manifests/base/registry/registry.yaml).
#
# Two-step delete per tag:
#   1. HEAD /v2/<repo>/manifests/<tag>  → Docker-Content-Digest: sha256:...
#   2. DELETE /v2/<repo>/manifests/<digest> → 202 Accepted
# Note: deleting a manifest by digest removes ALL tags pointing at the
# same digest (rare in this dev cluster, but possible if you `docker tag`
# the same image to two names).
#
# Usage (one subcommand required):
#   --list                 List every <repo>:<tag> in the registry.
#   --orphans              Print every <repo>:<tag> not referenced by any
#                          Pod / Deployment / StatefulSet / DaemonSet /
#                          ReplicaSet image: ref across the cluster
#                          (filtered to localhost:5443/*).
#   --rm <r:t> [<r:t>...]  Remove specific tag pointer(s).
#   --rm-orphans           Remove every tag from --orphans (with confirm).
#   --gc                   Run `registry garbage-collect --delete-untagged`
#                          inside the registry pod. Use after --rm or
#                          --rm-orphans to actually reclaim disk; can
#                          also run standalone.
#
# Flags:
#   -y, --yes              skip confirmation prompts
#   --dry-run              print what would happen without changing anything
#   -h, --help             this help
#
# Combine: --rm <...> --gc    and    --rm-orphans --gc    chain GC after.
#
# Env-var overrides:
#   REGISTRY_HOST        (default: localhost:5443)
#   REGISTRY_NAMESPACE   (default: registry)
#   REGISTRY_DEPLOYMENT  (default: k0s-registry)
#
# Examples:
#   bash scripts/prune-registry-tags.sh --list
#   bash scripts/prune-registry-tags.sh --orphans
#   bash scripts/prune-registry-tags.sh --rm positronic-control:mirror-test-20260427-135527 --gc
#   bash scripts/prune-registry-tags.sh --rm-orphans --gc -y
#   bash scripts/prune-registry-tags.sh --gc

set -u -o pipefail

REGISTRY_HOST="${REGISTRY_HOST:-localhost:5443}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry}"
REGISTRY_DEPLOYMENT="${REGISTRY_DEPLOYMENT:-k0s-registry}"
REG_URL="http://$REGISTRY_HOST"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; }

# kubectl resolution: prefer standalone kubectl, fall back to k0s kubectl
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v k0s >/dev/null 2>&1; then
  KUBECTL=(k0s kubectl)
else
  echo "error: no kubectl or k0s found in PATH" >&2; exit 2
fi

die()  { printf 'error: %s\n' "$*" >&2; exit 2; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# Manifest media types we'll accept on HEAD. Cover Docker v2 + OCI
# variants (single + index/list). Without these the registry may pick
# a default that doesn't match the bytes the tag actually resolves to,
# and the resulting digest wouldn't be deletable.
ACCEPT_HEADERS=(
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
  -H 'Accept: application/vnd.oci.image.manifest.v1+json'
  -H 'Accept: application/vnd.oci.image.index.v1+json'
)

list_registry_tags() {
  python3 - "$REGISTRY_HOST" <<'PY'
import json, sys, urllib.request, urllib.error
host = sys.argv[1]
def get(path):
    with urllib.request.urlopen(f"http://{host}{path}", timeout=10) as r:
        return json.loads(r.read())
try:
    repos = get("/v2/_catalog").get("repositories", []) or []
except urllib.error.URLError as e:
    print(f"error: registry unreachable at http://{host}: {e}", file=sys.stderr)
    sys.exit(2)
for repo in repos:
    try:
        d = get(f"/v2/{repo}/tags/list")
    except urllib.error.URLError as e:
        print(f"error: tag list failed for {repo}: {e}", file=sys.stderr)
        continue
    for tag in (d.get("tags") or []):
        print(f"{repo}:{tag}")
PY
}

list_inuse_tags() {
  # Emit one normalized <repo>:<tag> per cluster image: ref so it can be
  # compared directly against what list_registry_tags returns. Mapping
  # mirrors how the prime script and containerd's mirror routing
  # translate image refs into registry repo paths:
  #   localhost:5443/foo/bar:tag   -> foo/bar:tag      (strip mirror host)
  #   docker.io/foo/bar:tag        -> foo/bar:tag      (strip explicit docker.io)
  #   foundationbot/argus.user:qa  -> foundationbot/argus.user:qa
  #   mongo:7                      -> library/mongo:7  (Docker Hub library/* default)
  #   nginx                        -> library/nginx:latest
  # ReplicaSets (incl. those scaled to 0 from rollback history) are
  # deliberately omitted — their image refs are rollback waypoints, not
  # active usage. If you need to preserve rollback-history images,
  # remove them via explicit --rm rather than --orphans.
  "${KUBECTL[@]}" get pods,deployments,statefulsets,daemonsets -A \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null \
    | python3 -c '
import re, sys
host = sys.argv[1]
for line in sys.stdin:
    img = line.strip()
    if not img:
        continue
    # Track whether the ref was local-registry-built or Docker-Hub-style.
    # Only Docker Hub uses the implicit `library/` prefix; local-registry
    # repos (positronic-control, phantom-models) do not.
    if img.startswith(host + "/"):
        img = img[len(host) + 1:]
        is_dockerhub = False
    elif img.startswith("docker.io/"):
        img = img[len("docker.io/"):]
        is_dockerhub = True
    elif "." in img.split("/", 1)[0] or ":" in img.split("/", 1)[0]:
        # First path segment looks like a host (has dot or port colon),
        # e.g. ghcr.io/..., quay.io/..., 10.0.0.1:5000/... — not Docker Hub.
        is_dockerhub = False
    else:
        is_dockerhub = True
    if ":" in img.rsplit("/", 1)[-1]:
        repo, tag = img.rsplit(":", 1)
    else:
        repo, tag = img, "latest"
    if is_dockerhub and "/" not in repo:
        repo = "library/" + repo
    print(f"{repo}:{tag}")
' "$REGISTRY_HOST" \
    | sort -u
}

list_orphan_tags() {
  comm -23 <(list_registry_tags | sort -u) <(list_inuse_tags)
}

resolve_digest() {
  # Echo the manifest digest for <repo>:<tag>. Empty on failure.
  local repo="$1" tag="$2"
  curl -sI "${ACCEPT_HEADERS[@]}" "$REG_URL/v2/$repo/manifests/$tag" \
    | awk 'BEGIN{IGNORECASE=1}
           /^Docker-Content-Digest:/ {
             sub(/^[^:]+:[ \t]*/, ""); gsub(/[\r\n]/, ""); print; exit
           }'
}

remove_tag() {
  local entry="$1"
  local repo="${entry%:*}"
  local tag="${entry##*:}"
  local digest
  digest=$(resolve_digest "$repo" "$tag")
  if [ -z "$digest" ]; then
    fail "$entry  no digest returned (tag missing or registry refused our Accept headers)"
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  DELETE /v2/$repo/manifests/$digest  ($tag → $digest)"
    return 0
  fi
  local code
  code=$(curl -sX DELETE -o /dev/null -w '%{http_code}' "$REG_URL/v2/$repo/manifests/$digest")
  case "$code" in
    202) ok "$entry  ($digest)" ;;
    405) fail "$entry  HTTP 405 — REGISTRY_STORAGE_DELETE_ENABLED=true not set on the registry?"; return 1 ;;
    404) fail "$entry  HTTP 404 — manifest not found"; return 1 ;;
    *)   fail "$entry  unexpected HTTP $code"; return 1 ;;
  esac
}

run_gc() {
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  ${KUBECTL[*]} -n $REGISTRY_NAMESPACE exec deploy/$REGISTRY_DEPLOYMENT -- registry garbage-collect --delete-untagged /etc/docker/registry/config.yml"
    return
  fi
  echo "==> garbage-collect (this can take a moment)"
  "${KUBECTL[@]}" -n "$REGISTRY_NAMESPACE" exec deploy/"$REGISTRY_DEPLOYMENT" -- \
    registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
}

confirm() {
  [ "$YES" = 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r reply || return 1
  [[ "$reply" =~ ^[Yy] ]]
}

# parse args
ACTION=""
TARGETS=()
DO_GC=0
YES=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list)        ACTION=list; shift ;;
    --orphans)     ACTION=orphans; shift ;;
    --rm)
      ACTION=rm; shift
      while [ $# -gt 0 ] && [[ "$1" != -* ]]; do
        TARGETS+=("$1"); shift
      done
      ;;
    --rm-orphans)  ACTION=rm-orphans; shift ;;
    --gc)
      if [ -z "$ACTION" ]; then ACTION=gc; else DO_GC=1; fi
      shift
      ;;
    -y|--yes)      YES=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown arg: $1" ;;
  esac
done

[ -z "$ACTION" ] && { usage >&2; exit 2; }

case "$ACTION" in
  list)
    list_registry_tags | sort -u
    ;;

  orphans)
    list_orphan_tags
    ;;

  rm)
    [ "${#TARGETS[@]}" -eq 0 ] && die "--rm needs at least one <repo>:<tag>"
    echo "About to remove ${#TARGETS[@]} tag(s):"
    printf '  %s\n' "${TARGETS[@]}"
    confirm "Proceed?" || { echo "aborted"; exit 1; }
    fails=0
    for t in "${TARGETS[@]}"; do
      remove_tag "$t" || fails=$((fails + 1))
    done
    [ "$DO_GC" = 1 ] && run_gc
    exit "$fails"
    ;;

  rm-orphans)
    mapfile -t orphans < <(list_orphan_tags)
    if [ "${#orphans[@]}" -eq 0 ]; then
      echo "no orphan tags found."
      exit 0
    fi
    echo "Orphan tags (not referenced by any cluster workload):"
    printf '  %s\n' "${orphans[@]}"
    confirm "Remove all ${#orphans[@]}?" || { echo "aborted"; exit 1; }
    fails=0
    for t in "${orphans[@]}"; do
      remove_tag "$t" || fails=$((fails + 1))
    done
    [ "$DO_GC" = 1 ] && run_gc
    exit "$fails"
    ;;

  gc)
    confirm "Run registry garbage-collect (deletes blobs not referenced by any tag)?" || { echo "aborted"; exit 1; }
    run_gc
    ;;
esac
