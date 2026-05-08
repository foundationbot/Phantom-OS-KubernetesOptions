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
# can't be pulled from upstream (localhost:5443/* and *:PLACEHOLDER).
# Override with --from-file <path> (one image per line, # comments OK).
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
# Usage:
#   scripts/build-images-deb.sh                            # default: amd64+arm64
#   scripts/build-images-deb.sh --arch amd64               # narrow to one arch
#   scripts/build-images-deb.sh --from-file list.txt       # explicit image list
#   ARCHES=amd64 scripts/build-images-deb.sh               # env-var form
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
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -50
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
# {KERNEL_ARCH} for the requested arch, print one ref per line. No-op
# if the file is empty/absent.
read_extra_images_for_arch() {
  local arch="$1" kernel_arch line
  kernel_arch="$(_kernel_arch_for "$arch")"
  [ -n "$EXTRA_IMAGES_FILE" ] && [ -r "$EXTRA_IMAGES_FILE" ] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    line="${line//\{ARCH\}/$arch}"
    line="${line//\{KERNEL_ARCH\}/$kernel_arch}"
    printf '%s\n' "$line"
  done < "$EXTRA_IMAGES_FILE"
}

# ---- prerequisites ------------------------------------------------------

for tool in docker dpkg-deb rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build-images-deb.sh: required tool '$tool' not found in PATH" >&2
    [ "$tool" = docker ] \
      && echo "  hint: this script needs docker on the BUILD host (not the robot)" >&2
    exit 1
  fi
done

# ---- image discovery ----------------------------------------------------

discover_from_manifests() {
  # Mirrors the filter in scripts/prime-registry-cache.sh:
  #   - drop localhost:5443/* (those don't exist upstream)
  #   - drop *:PLACEHOLDER (template tag, replaced at deploy time)
  grep -rhE '^\s*image:\s*' manifests/ \
    | sed -E 's/^\s*image:\s*//; s/^["'\'']//; s/["'\'']$//' \
    | grep -v "^localhost:5443/" \
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

echo "Bundling ${#IMAGES[@]} image(s) for arches: ${ARCHES_LIST[*]}"
for i in "${IMAGES[@]}"; do echo "  - $i"; done
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
#   foundationbot/argus.auth:qa  ->  foundationbot--argus.auth_qa.tar
#   nginx:latest                 ->  nginx_latest.tar
sanitize_filename() {
  printf '%s' "$1" | sed 's|/|--|g; s|:|_|g'
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

# ---- per-arch build -----------------------------------------------------

# Track outcomes across arches for the final summary.
BUILT_DEBS=()
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
  local arch_images=("${IMAGES[@]}")
  local extra
  while IFS= read -r extra; do
    [ -n "$extra" ] && arch_images+=("$extra")
  done < <(read_extra_images_for_arch "$arch")

  if [ "${#arch_images[@]}" -gt "${#IMAGES[@]}" ]; then
    info_extra_count=$(( ${#arch_images[@]} - ${#IMAGES[@]} ))
    echo "  + ${info_extra_count} extra image(s) from $(basename "$EXTRA_IMAGES_FILE")"
  fi

  local included_images=() included_sizes=()
  local failed_images=() failed_reasons=()
  local img filename cache_path stage_path size

  for img in "${arch_images[@]}"; do
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

  {
    echo "Image bundle report"
    echo "==================="
    echo "Package:   $(basename "$deb_path")"
    echo "Version:   $VERSION"
    echo "Arch:      $arch"
    echo "Platform:  $platform"
    echo "Built:     $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
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
}

for arch in "${ARCHES_LIST[@]}"; do
  build_for_arch "$arch" || true
  echo
done

# ---- final summary ------------------------------------------------------

echo "=========================================================="
echo "Done. ${#BUILT_DEBS[@]} of ${#ARCHES_LIST[@]} arch(es) built."
echo "=========================================================="
for d in "${BUILT_DEBS[@]}"; do
  echo "  built: $d"
done
if [ "${#FAILED_ARCHES[@]}" -gt 0 ]; then
  for a in "${FAILED_ARCHES[@]}"; do
    echo "  FAILED: $a"
  done
  exit 1
fi
