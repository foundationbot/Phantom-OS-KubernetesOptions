#!/usr/bin/env bash
# build-images-deb.sh -- produce phantomos-k0s-images-<ver>-<arch>.deb
# files that drop pre-pulled Docker image tarballs into
# /var/lib/k0s/images/. k0s auto-imports anything in that directory at
# worker startup, so a robot that gets this .deb installed before
# bootstrap-robot.sh never needs to reach DockerHub at first boot.
#
# Companion to scripts/build-deb.sh: that one ships scripts + manifests;
# this one ships the image bytes those manifests reference.
#
# Discovery: scans manifests/ for `image:` lines, skipping refs that
# can't be pulled from upstream (*:PLACEHOLDER template tags).
# positronic-control / phantom-models / phantom-policies are now
# foundationbot/* images, so they're discovered and pulled from
# DockerHub like every other foundationbot/* ref. Override the scan
# with --from-file <path> (one image per line, # comments OK).
#
# Extra images: refs whose tag isn't in manifests/ (e.g. dma-ethercat,
# whose installer manifest carries :PLACEHOLDER and whose real tag is
# operator-supplied via host-config.yaml) can be added via
# packaging/deb-images/extra-images.txt (or --extra-images-file <path>).
# Per-line {ARCH} and {KERNEL_ARCH} are substituted at build time so a
# single template like
#   foundationbot/dma-ethercat:main-latest-{KERNEL_ARCH}
# expands to -amd64 in the amd64 .deb and -aarch64 in the arm64 .deb.
#
# Unpublished local builds (optional): if you have a positronic-control
# or phantom-models build that isn't on DockerHub yet, bundle it
# straight from the local docker daemon with --positronic-image <ref>
# and --phantom-models-image <ref> (refs must already be present in
# `docker images`). This is just an override for the normal DockerHub
# pull — leave the flags unset to bundle the published foundationbot/*
# images. Refs whose architecture doesn't match the build arch are
# skipped per-arch (no error).
#
# Multi-arch: defaults to building one .deb per architecture for both
# amd64 and arm64. Pass --arch <list> (or ARCHES=<list>) to narrow.
# Cross-arch pulls require docker on the build host to support the
# requested platform manifests (any modern docker does — no qemu/binfmt
# needed since we only `pull` and `save`, never run).
#
# Failure handling: images that fail to pull/save for a given arch are
# skipped and the .deb is still produced from whatever did succeed.
# A companion .report.txt is written next to each .deb.
#
# Caching: pulled image tarballs are kept under dist/build/image-cache/
# <arch>/ across runs. If a tar already exists there, the docker pull
# + docker save are skipped for that image. To force a re-pull (e.g.
# upstream :latest moved), delete the corresponding tar (or the whole
# arch cache dir).
#
# Output: by default each arch produces TWO artifacts (RFC 0007):
#   dist/<name>-<ver>-<arch>.deb       small (~30 KB) — manifest +
#                                       postinst only
#   dist/<name>-<ver>-<arch>.tar.zst   multi-GB sidecar — every image
#                                       tarball, zstd-compressed,
#                                       extracts to /var/lib/k0s/images/
# This dodges the .deb's 9.3 GB ar-member size cap. Pass
# --no-data-bundle (or NO_DATA_BUNDLE=1) to fall back to the legacy
# single-.deb output that embeds the tarballs directly.
#
# Usage:
#   scripts/build-images-deb.sh                            # default: amd64+arm64
#   scripts/build-images-deb.sh --arch amd64               # narrow to one arch
#   scripts/build-images-deb.sh --from-file list.txt       # explicit image list
#   ARCHES=amd64 scripts/build-images-deb.sh               # env-var form
#   scripts/build-images-deb.sh \
#     --positronic-image positronic-control:0.2.44-dev \
#     --phantom-models-image phantom-models:2026-05-09-dev
#                                                          # bundle unpublished local builds
#   scripts/build-images-deb.sh --no-data-bundle           # legacy single-.deb output
#                                                          # (embeds tarballs in the .deb;
#                                                          # only works under ~9.3 GB total)
#
# Prerequisites:
#   - docker (running, logged in to DockerHub for foundationbot/* images)
#   - dpkg-deb, rsync
#
# Note: the build host needs network + DockerHub access. The TARGET
# host (the robot) does not — that's the whole point.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PKG_NAME="${PKG_NAME:-phantomos-k0s-images}"
TARGET_DIR="/var/lib/k0s/images"

# Arch resolution precedence: --arch flag > ARCHES env > ARCH env > host.
ARCHES_FLAG=""
FROM_FILE=""
# Extra-images file: a list of additional image refs to bundle that
# aren't discoverable from manifests/ (for example the dma-ethercat
# installer image, whose tag lives in host-config.yaml — the manifest
# itself only carries a :PLACEHOLDER). Lines support per-arch templating
# via {ARCH} (debian arch: amd64, arm64) and {KERNEL_ARCH} (uname -m
# convention: amd64, aarch64). Default lookup path resolves to
# packaging/deb-images/extra-images.txt and is silently skipped if absent.
EXTRA_IMAGES_FILE_DEFAULT="$REPO_ROOT/packaging/deb-images/extra-images.txt"
EXTRA_IMAGES_FILE="${EXTRA_IMAGES_FILE:-}"
# Unpublished local-build overrides (already present in `docker images`).
# Empty by default; populated only by flag/env. Use these to bundle a
# positronic-control / phantom-models build that isn't on DockerHub yet;
# otherwise the published foundationbot/* images are discovered and
# pulled normally. The values are full refs (e.g.
# positronic-control:0.2.44-dev).
POSITRONIC_IMAGE="${POSITRONIC_IMAGE:-}"
PHANTOM_MODELS_IMAGE="${PHANTOM_MODELS_IMAGE:-}"
# Retained as an accepted no-op for backward compatibility: the script
# no longer prompts interactively (local-build refs come from flags/env
# only), so there is nothing to suppress.
NO_PROMPT="${NO_PROMPT:-0}"
# When set to 1, skips the per-arch sidecar tar.zst (see RFC 0007). The
# .deb then ships the tarballs the old way (under /var/lib/k0s/images/)
# and the operator distributes nothing else. Useful for backward-compat
# debugging or when the tarballs are shipped via a separate channel
# (S3/rsync) and the operator only wants the manifest-bearing .deb.
NO_DATA_BUNDLE="${NO_DATA_BUNDLE:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-file)
      [ -r "${2:-}" ] || { echo "error: --from-file needs a readable path" >&2; exit 2; }
      FROM_FILE="$2"; shift 2 ;;
    --extra-images-file)
      [ -r "${2:-}" ] || { echo "error: --extra-images-file needs a readable path" >&2; exit 2; }
      EXTRA_IMAGES_FILE="$2"; shift 2 ;;
    --arch)
      [ -n "${2:-}" ] || { echo "error: --arch needs a value (e.g. amd64,arm64)" >&2; exit 2; }
      ARCHES_FLAG="$2"; shift 2 ;;
    --positronic-image)
      [ -n "${2:-}" ] || { echo "error: --positronic-image needs a value" >&2; exit 2; }
      POSITRONIC_IMAGE="$2"; shift 2 ;;
    --phantom-models-image)
      [ -n "${2:-}" ] || { echo "error: --phantom-models-image needs a value" >&2; exit 2; }
      PHANTOM_MODELS_IMAGE="$2"; shift 2 ;;
    --no-prompt)
      # Accepted no-op (no interactive prompts remain); kept for back-compat.
      NO_PROMPT=1; shift ;;
    --no-data-bundle)
      NO_DATA_BUNDLE=1; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -60
      exit 0 ;;
    *)
      echo "error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$ARCHES_FLAG" ]; then
  ARCHES_RAW="$ARCHES_FLAG"
elif [ -n "${ARCHES:-}" ]; then
  ARCHES_RAW="$ARCHES"
elif [ -n "${ARCH:-}" ]; then
  ARCHES_RAW="$ARCH"
else
  # Robots ship as a mix of amd64 (x86 dev hosts) and arm64 (Jetson),
  # so the default produces one .deb per architecture. Pass --arch to
  # narrow if you only need one.
  ARCHES_RAW="amd64,arm64"
fi

IFS=',' read -r -a ARCHES_LIST <<<"$ARCHES_RAW"
# Trim whitespace from each entry and drop empties.
TMP=()
for a in "${ARCHES_LIST[@]}"; do
  a="$(printf '%s' "$a" | tr -d '[:space:]')"
  [ -n "$a" ] && TMP+=("$a")
done
ARCHES_LIST=("${TMP[@]}")
unset TMP

if [ "${#ARCHES_LIST[@]}" -eq 0 ]; then
  echo "build-images-deb.sh: no architectures specified" >&2; exit 2
fi

# If --extra-images-file wasn't passed, fall back to the default path
# but only if the file actually exists (silent no-op otherwise).
if [ -z "$EXTRA_IMAGES_FILE" ] && [ -r "$EXTRA_IMAGES_FILE_DEFAULT" ]; then
  EXTRA_IMAGES_FILE="$EXTRA_IMAGES_FILE_DEFAULT"
fi

# Map a debian arch to the kernel/uname convention so refs like
# foundationbot/dma-ethercat:main-latest-{KERNEL_ARCH} resolve
# correctly (arm64 -> aarch64, amd64 -> amd64). Anything unknown
# passes through unchanged.
_kernel_arch_for() {
  case "$1" in
    arm64) printf 'aarch64' ;;
    amd64) printf 'amd64' ;;
    *)     printf '%s' "$1" ;;
  esac
}

# Read EXTRA_IMAGES_FILE, drop comments/blanks, substitute {ARCH} and
# {KERNEL_ARCH}, honor per-line `# arch:<arch>[,<arch>...]` filters,
# and print one ref per line for the requested arch. No-op if the file
# is empty/absent.
#
# Line formats:
#   foundationbot/dma-ethercat:main-latest-{KERNEL_ARCH}
#       Templated; expands to the right tag for each arch.
#   foundationbot/dma-ethercat:main-latest-amd64    # arch:amd64
#       Pinned to one arch; lines for other arches are skipped.
#   foundationbot/dma-ethercat:custom-tag           # arch:amd64,arm64
#       Same line in multiple arches (rarely useful, supported anyway).
read_extra_images_for_arch() {
  local arch="$1" kernel_arch line ref filter filter_csv match
  kernel_arch="$(_kernel_arch_for "$arch")"
  [ -n "$EXTRA_IMAGES_FILE" ] && [ -r "$EXTRA_IMAGES_FILE" ] || return 0
  while IFS= read -r line; do
    # Pull out any `# arch:<csv>` filter before stripping comments.
    filter=""
    if printf '%s' "$line" | grep -qE '#[[:space:]]*arch:'; then
      filter="$(printf '%s' "$line" | sed -nE 's/.*#[[:space:]]*arch:([^[:space:]#]+).*/\1/p')"
    fi
    # Strip comments and whitespace from the ref.
    ref="${line%%#*}"
    ref="$(printf '%s' "$ref" | tr -d '[:space:]')"
    [ -z "$ref" ] && continue
    # Apply the arch filter if present.
    if [ -n "$filter" ]; then
      match=0
      filter_csv=",${filter},"
      case "$filter_csv" in *,${arch},*) match=1 ;; esac
      [ "$match" = 0 ] && continue
    fi
    # Now do template substitution.
    ref="${ref//\{ARCH\}/$arch}"
    ref="${ref//\{KERNEL_ARCH\}/$kernel_arch}"
    printf '%s\n' "$ref"
  done < "$EXTRA_IMAGES_FILE"
}

# ---- prerequisites ------------------------------------------------------

_prereq_tools=(docker dpkg-deb rsync tar)
# zstd is only needed when building the sidecar tar.zst (RFC 0007).
# Skip the check when --no-data-bundle is set so a build host without
# zstd can still produce the legacy single-.deb output.
if [ "$NO_DATA_BUNDLE" != 1 ]; then
  _prereq_tools+=(zstd)
fi
for tool in "${_prereq_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build-images-deb.sh: required tool '$tool' not found in PATH" >&2
    [ "$tool" = docker ] \
      && echo "  hint: this script needs docker on the BUILD host (not the robot)" >&2
    [ "$tool" = zstd ] \
      && echo "  hint: needed for the sidecar tar.zst; install zstd or pass --no-data-bundle" >&2
    exit 1
  fi
done
unset _prereq_tools

# ---- image discovery ----------------------------------------------------

discover_from_manifests() {
  #   - drop *:PLACEHOLDER (template tag, replaced at deploy time)
  # Everything else (all foundationbot/* refs) is pulled from DockerHub.
  grep -rhE '^\s*image:\s*' manifests/ \
    | sed -E 's/^\s*image:\s*//; s/^["'\'']//; s/["'\'']$//' \
    | grep -v ':PLACEHOLDER$' \
    | grep -v '^$' \
    | sort -u
}

if [ -n "$FROM_FILE" ]; then
  IMAGES=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && IMAGES+=("$line")
  done < "$FROM_FILE"
else
  IMAGES=()
  while IFS= read -r line; do
    [ -n "$line" ] && IMAGES+=("$line")
  done < <(discover_from_manifests)
fi

if [ "${#IMAGES[@]}" -eq 0 ]; then
  echo "error: no images to bundle (manifests/ scan empty and no --from-file)" >&2
  exit 1
fi

# ---- bundle manifest helpers -------------------------------------------
#
# RFC 0005 phase 1: the .deb ships a sidecar at
# /var/lib/k0s/images/.phantomos-image-bundle.yaml that records, for
# each canonical container the wizard knows about (positronic-control,
# phantom-models, operator-ui, dma-ethercat), which tarball satisfies
# it. The wizard reads this on re-runs to pre-fill image overrides
# without operator typing.
#
# Phase 1 embeds the repo->container lookup directly here. Phase 2 will
# extract it to packaging/canonical-containers.yaml shared with
# scripts/lib/host-config.py CONTAINER_TARGETS.
#
# canonical_container_for_repo <repo>
#   Print the canonical container name for the given repository (no
#   tag, no digest) using the four-row lookup, or nothing if the repo
#   doesn't satisfy a canonical container. Callers handle the
#   --positronic-image / --phantom-models-image flag overrides
#   separately, since those flags carry operator intent that the lookup
#   cannot infer (e.g. a swap-repo like foundationbot/phantom-cuda).
canonical_container_for_repo() {
  case "$1" in
    foundationbot/positronic-control)  printf 'positronic-control' ;;
    foundationbot/phantom-models)      printf 'phantom-models' ;;
    foundationbot/argus.operator-ui)   printf 'operator-ui' ;;
    foundationbot/dma-ethercat)        printf 'dma-ethercat' ;;
    *) : ;;
  esac
}

# Top-level source tracking: mirrors IMAGES[] / LOCAL_IMAGES[] with the
# matching `source` value the bundle manifest will record. Indexed by
# array position. Per-arch extras (read_extra_images_for_arch) are
# tagged on the fly inside build_for_arch since their refs depend on
# {ARCH}/{KERNEL_ARCH} substitution.
IMAGE_SOURCES=()
if [ -n "$FROM_FILE" ]; then
  # --from-file is operator-supplied — treat each line as an
  # extra-images entry (closest semantic match in the schema).
  for _ in "${IMAGES[@]}"; do IMAGE_SOURCES+=("extra-images"); done
else
  for _ in "${IMAGES[@]}"; do IMAGE_SOURCES+=("manifest-scan"); done
fi

# ---- unpublished local-build overrides ---------------------------------
#
# positronic-control / phantom-models / phantom-policies normally come
# from DockerHub (foundationbot/*) via the manifest scan above. The
# --positronic-image / --phantom-models-image flags are an optional
# escape hatch for bundling a local build that isn't on DockerHub yet:
# the ref must already exist in the local docker daemon and is saved
# straight from it (no pull). `docker image inspect` is the gate — if
# the ref isn't present locally, we don't try to do anything clever
# (no auto-build, no implicit `docker tag`).

# Verify each supplied ref exists locally — fail fast rather than
# discovering it per-arch inside the build loop. A ref that's present
# but built for a different platform is allowed through here; the
# per-arch save_local_image() check skips it cleanly for that arch.
for pair in "positronic-control:$POSITRONIC_IMAGE" "phantom-models:$PHANTOM_MODELS_IMAGE"; do
  label="${pair%%:*}"
  ref="${pair#*:}"
  [ -z "$ref" ] && continue
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    echo "error: $label ref '$ref' not found in local docker daemon" >&2
    echo "  hint: 'docker images $ref' — build/tag it first" >&2
    exit 1
  fi
done

LOCAL_IMAGES=()
# Parallel array tracking which canonical container each LOCAL_IMAGES[i]
# satisfies. The flag carries operator intent — the repo on the flag
# may be a swap (e.g. foundationbot/phantom-cuda for positronic-control)
# that the lookup table cannot identify, so the canonical-container
# binding has to come from the flag itself, not from the ref.
LOCAL_IMAGE_CONTAINERS=()
if [ -n "$POSITRONIC_IMAGE" ]; then
  LOCAL_IMAGES+=("$POSITRONIC_IMAGE")
  LOCAL_IMAGE_CONTAINERS+=("positronic-control")
fi
if [ -n "$PHANTOM_MODELS_IMAGE" ]; then
  LOCAL_IMAGES+=("$PHANTOM_MODELS_IMAGE")
  LOCAL_IMAGE_CONTAINERS+=("phantom-models")
fi

echo "Bundling ${#IMAGES[@]} pullable image(s) for arches: ${ARCHES_LIST[*]}"
for i in "${IMAGES[@]}"; do echo "  - $i"; done
if [ "${#LOCAL_IMAGES[@]}" -gt 0 ]; then
  echo "Bundling ${#LOCAL_IMAGES[@]} unpublished local-build image(s) (saved straight from docker daemon):"
  for i in "${LOCAL_IMAGES[@]}"; do echo "  - $i"; done
fi
echo

# ---- version derivation -------------------------------------------------
# Same scheme as scripts/build-deb.sh so the two .debs ship in lockstep.

derive_version() {
  if [ -n "${VERSION:-}" ]; then
    printf '%s' "$VERSION"
    return
  fi
  if [ ! -f "$REPO_ROOT/version.txt" ]; then
    echo "build-images-deb.sh: version.txt not found at $REPO_ROOT/version.txt" >&2
    exit 1
  fi
  local base date sha
  base="$(tr -d '[:space:]' < "$REPO_ROOT/version.txt")"
  if [ -z "$base" ]; then
    echo "build-images-deb.sh: version.txt is empty" >&2
    exit 1
  fi
  if sha=$(git rev-parse --short=7 HEAD 2>/dev/null); then
    date=$(date -u +%Y%m%d)
    base="${base}+${date}.g${sha}"
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      base="${base}+dirty"
    fi
  fi
  printf '%s' "$base"
}

VERSION="$(derive_version)"
DEB_MAINTAINER="${DEB_MAINTAINER:-Foundation Bot <ops@foundation.bot>}"

case "$VERSION" in
  *' '*|*/*) echo "build-images-deb.sh: invalid VERSION '$VERSION'" >&2; exit 1 ;;
esac

DIST_DIR="$REPO_ROOT/dist"
CONTROL_IN="packaging/deb-images/control.in"
if [ ! -r "$CONTROL_IN" ]; then
  echo "build-images-deb.sh: missing $CONTROL_IN (cannot generate DEBIAN/control)" >&2
  exit 1
fi

# Filename mirrors build-deb.sh: dots and pluses flattened to hyphens
# for readability; embedded Version: field keeps them for proper
# dpkg/apt sort ordering.
FILENAME_VERSION="${VERSION//./-}"
FILENAME_VERSION="${FILENAME_VERSION//+/-}"

# Sanitize an image ref into a filesystem-safe filename.
#   foundationbot/argus.auth:qa  ->  foundationbot-argus.auth_qa.tar
#   nginx:latest                 ->  nginx_latest.tar
sanitize_filename() {
  printf '%s' "$1" | sed 's|/|-|g; s|:|_|g'
}

# Strip an image ref to just its repository (no tag, no digest).
#   foundationbot/argus.auth:qa            -> foundationbot/argus.auth
#   alpine@sha256:abc                      -> alpine
#   registry.example.com:5000/foo/bar:tag  -> registry.example.com:5000/foo/bar
image_repo() {
  local ref="$1"
  ref="${ref%@*}"
  # Drop a trailing tag only if it's after the LAST slash. A colon in
  # the host:port part of a registry must not be stripped.
  case "$ref" in
    */*:*) printf '%s' "${ref%:*}" ;;
    *:*)   printf '%s' "${ref%:*}" ;;
    *)     printf '%s' "$ref" ;;
  esac
}

# Look up the per-platform manifest digest for an image's manifest list.
# Prints the digest on success (sha256:...), nothing on failure.
# Falls back silently if buildx is unavailable or the image is single-
# manifest.
resolve_arch_digest() {
  local img="$1" arch="$2"
  docker buildx imagetools inspect "$img" --format \
    "{{range .Manifest.Manifests}}{{if and (eq .Platform.OS \"linux\") (eq .Platform.Architecture \"$arch\")}}{{.Digest}}{{end}}{{end}}" \
    2>/dev/null | tr -d '[:space:]'
}

# Pull a specific platform's image cleanly and save it as a docker-
# format tarball at $out_path. Goes through digest resolution to dodge
# the docker/containerd-snapshotter bug where cross-platform `--platform`
# pulls leave manifest references that `docker save` can't resolve.
#
# Returns 0 on success. On failure, prints to stderr and returns
# non-zero with a reason in the global $PULL_FAIL_REASON.
PULL_FAIL_REASON=""
pull_and_save_arch() {
  local img="$1" arch="$2" platform="$3" out_path="$4"
  local digest repo by_digest
  PULL_FAIL_REASON=""

  repo="$(image_repo "$img")"
  digest="$(resolve_arch_digest "$img" "$arch")"

  if [ -n "$digest" ]; then
    by_digest="${repo}@${digest}"
    if ! docker pull --platform "$platform" -q "$by_digest" >/dev/null 2>&1; then
      PULL_FAIL_REASON="pull failed (by digest)"
      return 1
    fi
    # Re-tag so the saved tarball's manifest.json carries the original
    # ref — k0s/containerd needs that to satisfy `image: $img` lookups.
    if ! docker tag "$by_digest" "$img" 2>/dev/null; then
      PULL_FAIL_REASON="docker tag failed"
      return 1
    fi
    if ! docker save "$img" -o "$out_path" 2>/dev/null; then
      PULL_FAIL_REASON="save failed (post-digest-pull)"
      rm -f "$out_path"
      return 1
    fi
    # Best-effort cleanup of the digest reference; the tag we created
    # stays in the daemon for the rest of this run.
    docker rmi "$by_digest" >/dev/null 2>&1 || true
    return 0
  fi

  # No multi-arch manifest list (single-arch image). Fall back to a
  # plain platform pull. If the image's only platform doesn't match
  # the requested arch, the pull itself will fail.
  docker image rm -f "$img" >/dev/null 2>&1 || true
  if ! docker pull --platform "$platform" -q "$img" >/dev/null 2>&1; then
    PULL_FAIL_REASON="pull failed (no $arch manifest?)"
    return 1
  fi
  if ! docker save "$img" -o "$out_path" 2>/dev/null; then
    PULL_FAIL_REASON="save failed"
    rm -f "$out_path"
    return 1
  fi
  return 0
}

# Save a ref that's already present in the local docker daemon to a
# tarball. Verifies the image's architecture matches the build arch and
# silently skips (return 2) when it doesn't, so a developer who builds
# only for their own host's arch doesn't get a hard failure on the
# other arch's .deb. Hard failures (return 1) are reserved for
# unexpected docker errors. Reason ends up in PULL_FAIL_REASON.
save_local_image() {
  local img="$1" arch="$2" out_path="$3"
  local img_arch
  PULL_FAIL_REASON=""

  if ! docker image inspect "$img" >/dev/null 2>&1; then
    PULL_FAIL_REASON="not present in local docker daemon"
    return 1
  fi
  img_arch="$(docker image inspect --format '{{.Architecture}}' "$img" 2>/dev/null || true)"
  if [ -n "$img_arch" ] && [ "$img_arch" != "$arch" ]; then
    PULL_FAIL_REASON="local image is $img_arch, build is $arch (skipping)"
    return 2
  fi
  if ! docker save "$img" -o "$out_path" 2>/dev/null; then
    PULL_FAIL_REASON="docker save failed"
    rm -f "$out_path"
    return 1
  fi
  return 0
}

# ---- per-arch build -----------------------------------------------------

# Track outcomes across arches for the final summary.
BUILT_DEBS=()
BUILT_SIDECARS=()
FAILED_ARCHES=()

build_for_arch() {
  local arch="$1"
  local platform="linux/${arch}"
  local stage_dir="$DIST_DIR/build/${PKG_NAME}_${VERSION}_${arch}"
  local cache_dir="$DIST_DIR/build/image-cache/${arch}"
  local deb_path="$DIST_DIR/${PKG_NAME}-${FILENAME_VERSION}-${arch}.deb"
  local report_path="${deb_path%.deb}.report.txt"

  echo "=========================================================="
  echo "Building for ${arch} (${platform})"
  echo "=========================================================="

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir/DEBIAN"
  mkdir -p "$stage_dir$TARGET_DIR"
  mkdir -p "$cache_dir"

  # Per-arch image list: discovered/explicit images first, then any
  # extras from EXTRA_IMAGES_FILE with {ARCH}/{KERNEL_ARCH} resolved.
  # arch_image_sources[] is the parallel `source` (manifest-scan |
  # extra-images | flag) tracked for the bundle manifest sidecar.
  local arch_images=("${IMAGES[@]}")
  local arch_image_sources=("${IMAGE_SOURCES[@]}")
  local extra
  while IFS= read -r extra; do
    if [ -n "$extra" ]; then
      arch_images+=("$extra")
      arch_image_sources+=("extra-images")
    fi
  done < <(read_extra_images_for_arch "$arch")

  if [ "${#arch_images[@]}" -gt "${#IMAGES[@]}" ]; then
    info_extra_count=$(( ${#arch_images[@]} - ${#IMAGES[@]} ))
    echo "  + ${info_extra_count} extra image(s) from $(basename "$EXTRA_IMAGES_FILE")"
  fi

  local included_images=() included_sizes=()
  local failed_images=() failed_reasons=()
  # Bundle-manifest accumulators (RFC 0005 phase 1). Parallel arrays of
  # the canonical entries — only canonical containers are listed; other
  # tarballs (mongo, nginx, redis, ...) are simply not recorded.
  local bundle_containers=() bundle_refs=() bundle_tarballs=() bundle_sources=()
  local img filename cache_path stage_path size
  local idx src container repo

  for idx in "${!arch_images[@]}"; do
    img="${arch_images[$idx]}"
    src="${arch_image_sources[$idx]}"
    filename="$(sanitize_filename "$img").tar"
    cache_path="$cache_dir/$filename"
    stage_path="$stage_dir$TARGET_DIR/$filename"

    if [ -s "$cache_path" ]; then
      printf '==> %s\n    cached: %s\n' "$img" "$filename"
    else
      printf '==> %s\n' "$img"
      if ! pull_and_save_arch "$img" "$arch" "$platform" "$cache_path"; then
        printf '    SKIP: %s\n' "$PULL_FAIL_REASON" >&2
        failed_images+=("$img")
        failed_reasons+=("$PULL_FAIL_REASON")
        continue
      fi
      printf '    saved %s\n' "$filename"
    fi

    # Hardlink the cached tar into the staging tree (same FS, so cheap).
    # Fall back to copy if hardlink fails for any reason.
    ln -f "$cache_path" "$stage_path" 2>/dev/null || cp "$cache_path" "$stage_path"

    size=$(du -h "$cache_path" 2>/dev/null | awk '{print $1}')
    included_images+=("$img")
    included_sizes+=("${size:-?}")

    # If this image's repo matches a canonical container, record an
    # entry for the bundle manifest. Non-canonical refs (mongo, redis,
    # ...) are deliberately omitted — the wizard has nothing to do with
    # them.
    repo="$(image_repo "$img")"
    container="$(canonical_container_for_repo "$repo")"
    if [ -n "$container" ]; then
      bundle_containers+=("$container")
      bundle_refs+=("$img")
      bundle_tarballs+=("$filename")
      bundle_sources+=("$src")
    fi
  done

  # Local-only images (positronic-control, phantom-models). Saved
  # straight from the local docker daemon — no pull. NOT cached across
  # runs: the same tag commonly points at a freshly-rebuilt image
  # between runs, and a stale cache would silently ship the wrong
  # bytes. We always re-save.
  local rc
  for idx in "${!LOCAL_IMAGES[@]}"; do
    img="${LOCAL_IMAGES[$idx]}"
    container="${LOCAL_IMAGE_CONTAINERS[$idx]}"
    filename="$(sanitize_filename "$img").tar"
    stage_path="$stage_dir$TARGET_DIR/$filename"
    printf '==> %s  (local)\n' "$img"
    if save_local_image "$img" "$arch" "$stage_path"; then
      printf '    saved %s\n' "$filename"
      size=$(du -h "$stage_path" 2>/dev/null | awk '{print $1}')
      included_images+=("$img")
      included_sizes+=("${size:-?}")
      # Flag-supplied images always map to a canonical container by
      # operator intent (the flag IS the assignment), so the bundle
      # entry is unconditional — no repo lookup, no skip.
      bundle_containers+=("$container")
      bundle_refs+=("$img")
      bundle_tarballs+=("$filename")
      bundle_sources+=("flag")
    else
      rc=$?
      # rc=2 is "wrong arch for this build" — informational, not a
      # failure, since dev hosts typically build for one arch only.
      if [ "$rc" = 2 ]; then
        printf '    skip: %s\n' "$PULL_FAIL_REASON" >&2
      else
        printf '    SKIP: %s\n' "$PULL_FAIL_REASON" >&2
        failed_images+=("$img")
        failed_reasons+=("$PULL_FAIL_REASON")
      fi
    fi
  done

  local ok="${#included_images[@]}"
  local failed="${#failed_images[@]}"

  if [ "$ok" -eq 0 ]; then
    echo
    echo "build-images-deb.sh[$arch]: no images successfully pulled; skipping .deb." >&2
    FAILED_ARCHES+=("$arch")
    return 1
  fi

  chmod 0644 "$stage_dir$TARGET_DIR"/*.tar
  find "$stage_dir$TARGET_DIR" -type d -exec chmod 0755 {} +

  # ---- bundle manifest sidecar (RFC 0005 phase 1) ----------------------
  #
  # The dot-prefix keeps it out of k0s's auto-import scan
  # (k0s ignores hidden files in /var/lib/k0s/images/). The wizard
  # (configure-host.sh) reads this on re-runs to default the four
  # canonical-container image rows from build-time intent rather than
  # asking the operator to re-type tags. stage_dir is rm -rf'd at the
  # top of build_for_arch, so we always write fresh — no idempotency
  # dance needed.
  local manifest_path="$stage_dir$TARGET_DIR/.phantomos-image-bundle.yaml"
  local built_at
  built_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    printf 'schemaVersion: 1\n'
    printf 'builtAt: %s\n' "$built_at"
    printf 'builderVersion: %s\n' "$VERSION"
    printf 'arch: %s\n' "$arch"
    printf 'bundle:\n'
    local bi
    for bi in "${!bundle_containers[@]}"; do
      printf '  - container: %s\n' "${bundle_containers[$bi]}"
      printf '    ref: %s\n'       "${bundle_refs[$bi]}"
      printf '    tarball: %s\n'   "${bundle_tarballs[$bi]}"
      printf '    source: %s\n'    "${bundle_sources[$bi]}"
    done
  } > "$manifest_path"
  chmod 0644 "$manifest_path"
  if [ "${#bundle_containers[@]}" -gt 0 ]; then
    local _bc_csv
    _bc_csv="$(IFS=,; printf '%s' "${bundle_containers[*]}")"
    _bc_csv="${_bc_csv//,/, }"
    echo "bundle manifest: ${#bundle_containers[@]} canonical entries (${_bc_csv})"
  else
    echo "bundle manifest: 0 canonical entries"
  fi

  # ---- sidecar tar.zst (RFC 0007 phase 1) ------------------------------
  #
  # Pack every staged *.tar into a sibling tar.zst alongside the .deb.
  # This escapes the .deb's ar member size cap (~9.3 GB) — phantom-cuda
  # alone is bigger than that. The .yaml manifest STAYS in the .deb;
  # only the *.tar bytes move out.
  #
  # Tar layout: relative paths so `tar -xf <sidecar> -C /` lands the
  # tarballs at /var/lib/k0s/images/. We tar from $stage_dir as the
  # base and include `var/lib/k0s/images/`, excluding the manifest so
  # it doesn't end up in both artifacts.
  local sidecar_path="" sidecar_tarball_count=0
  local sidecar_human_size=""
  if [ "$NO_DATA_BUNDLE" != 1 ]; then
    sidecar_path="${deb_path%.deb}.tar.zst"
    # Count the tarballs that will go into the sidecar — purely
    # informational; an empty stage tree shouldn't reach this branch
    # (ok==0 would have returned above).
    sidecar_tarball_count=$(find "$stage_dir$TARGET_DIR" -maxdepth 1 -name '*.tar' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "sidecar: writing $(basename "$sidecar_path") (${sidecar_tarball_count} tarball(s), zstd -9)"
    rm -f "$sidecar_path"
    # The TARGET_DIR-relative path inside the archive is "var/lib/k0s/images"
    # (no leading slash) — strip the leading / off TARGET_DIR for the
    # tar invocation. --exclude keeps the .yaml manifest out of the
    # sidecar so it stays a .deb-only artifact. --mtime + --sort flatten
    # timestamps for slightly more reproducible tars; harmless if the
    # local tar doesn't accept --sort (it falls through to the file
    # order from the FS, which we accept).
    local tar_rel="${TARGET_DIR#/}"
    if ! tar \
        --owner=0 --group=0 --numeric-owner \
        --mtime='@0' \
        --sort=name \
        --exclude='.phantomos-image-bundle.yaml' \
        -C "$stage_dir" \
        -cf - "$tar_rel" \
      | zstd -9 -T0 -q -o "$sidecar_path"; then
      echo "build-images-deb.sh[$arch]: sidecar tar|zstd pipeline failed" >&2
      rm -f "$sidecar_path"
      FAILED_ARCHES+=("$arch")
      return 1
    fi
    if [ ! -s "$sidecar_path" ]; then
      echo "build-images-deb.sh[$arch]: sidecar produced zero bytes (zstd silent failure?)" >&2
      rm -f "$sidecar_path"
      FAILED_ARCHES+=("$arch")
      return 1
    fi
    sidecar_human_size=$(du -h "$sidecar_path" 2>/dev/null | awk '{print $1}')
    echo "sidecar: $sidecar_path (${sidecar_tarball_count} tarballs, ${sidecar_human_size:-?})"

    # Now strip the staged *.tar files so the .deb only carries the
    # manifest + DEBIAN/. Use `rm -f *.tar` rather than `rm -rf` so
    # the directory and the manifest are preserved.
    rm -f "$stage_dir$TARGET_DIR"/*.tar
  fi

  local installed_size
  installed_size=$(du -sk "$stage_dir$TARGET_DIR" | awk '{print $1}')

  sed \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@ARCH@|$arch|g" \
    -e "s|@MAINTAINER@|$DEB_MAINTAINER|g" \
    -e "s|@INSTALLED_SIZE@|$installed_size|g" \
    "$CONTROL_IN" > "$stage_dir/DEBIAN/control"

  local f
  for f in preinst postinst prerm postrm; do
    if [ -f "packaging/deb-images/$f" ]; then
      install -m 0755 "packaging/deb-images/$f" "$stage_dir/DEBIAN/$f"
    fi
  done

  mkdir -p "$DIST_DIR"
  if ! dpkg-deb --build --root-owner-group "$stage_dir" "$deb_path"; then
    echo "build-images-deb.sh[$arch]: dpkg-deb --build failed; no .deb produced." >&2
    FAILED_ARCHES+=("$arch")
    return 1
  fi

  echo
  echo "built: $deb_path  ($ok image(s), $(du -h "$deb_path" | awk '{print $1}'))"
  echo
  dpkg-deb -I "$deb_path" | sed 's/^/  /'

  local deb_human_size
  deb_human_size=$(du -h "$deb_path" 2>/dev/null | awk '{print $1}')

  {
    echo "Image bundle report"
    echo "==================="
    echo "Package:   $(basename "$deb_path")"
    echo "Version:   $VERSION"
    echo "Arch:      $arch"
    echo "Platform:  $platform"
    echo "Built:     $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "Artifacts:"
    printf '  deb:          %s (%s)\n' "$deb_path" "${deb_human_size:-?}"
    if [ -n "$sidecar_path" ]; then
      printf '  data bundle:  %s (%s, %d tarball(s))\n' \
        "$sidecar_path" "${sidecar_human_size:-?}" "$sidecar_tarball_count"
    fi
    echo
    echo "Included (${ok}):"
    local i
    for i in "${!included_images[@]}"; do
      printf '  + %s  (%s)\n' "${included_images[$i]}" "${included_sizes[$i]}"
    done
    if [ "$failed" -gt 0 ]; then
      echo
      echo "Skipped (${failed}):"
      for i in "${!failed_images[@]}"; do
        printf '  - %s  (%s)\n' "${failed_images[$i]}" "${failed_reasons[$i]}"
      done
    fi
  } | tee "$report_path"

  echo
  echo "report: $report_path"
  BUILT_DEBS+=("$deb_path")
  if [ -n "$sidecar_path" ]; then
    BUILT_SIDECARS+=("$sidecar_path")
  else
    # Keep arrays positionally aligned even when no sidecar so the
    # final summary can pair entries up by index.
    BUILT_SIDECARS+=("")
  fi
}

for arch in "${ARCHES_LIST[@]}"; do
  build_for_arch "$arch" || true
  echo
done

# ---- final summary ------------------------------------------------------

echo "=========================================================="
echo "Done. ${#BUILT_DEBS[@]} of ${#ARCHES_LIST[@]} arch(es) built."
echo "=========================================================="
for i in "${!BUILT_DEBS[@]}"; do
  echo "  built: ${BUILT_DEBS[$i]}"
  if [ -n "${BUILT_SIDECARS[$i]:-}" ]; then
    echo "         ${BUILT_SIDECARS[$i]}"
  fi
done
if [ "${#FAILED_ARCHES[@]}" -gt 0 ]; then
  for a in "${FAILED_ARCHES[@]}"; do
    echo "  FAILED: $a"
  done
  exit 1
fi
