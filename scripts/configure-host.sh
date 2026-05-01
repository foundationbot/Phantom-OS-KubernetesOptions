#!/usr/bin/env bash
# configure-host.sh — interactive editor for /etc/phantomos/host-config.yaml.
#
# Walks the operator through the per-host config fields (robot identity,
# AI PC URL, image tag overrides) with defaults and examples, then
# writes the result. Companion to scripts/bootstrap-robot.sh — run this
# once on a fresh machine, then bootstrap-robot.sh consumes the file.
#
# Usage:
#   sudo bash scripts/configure-host.sh                   # full wizard
#   sudo bash scripts/configure-host.sh --from-template mk09
#                                                          # pre-fill from
#                                                          # host-config-templates/mk09/host-config.yaml
#   sudo bash scripts/configure-host.sh --output /tmp/hc.yaml --no-write
#                                                          # render to a
#                                                          # custom path
#                                                          # without root
#   sudo bash scripts/configure-host.sh --show             # print current
#                                                          # host-config
#   sudo bash scripts/configure-host.sh --validate         # validate
#                                                          # current host-config
#
# Flags:
#   --from-template <robot>  pre-fill from host-config-templates/<robot>/host-config.yaml
#   --output <path>          target file (default: /etc/phantomos/host-config.yaml)
#   --no-write               write only if user confirms (always on by default,
#                            included for symmetry with --yes)
#   -y, --yes                accept all defaults, no prompts
#   --show                   print the current host-config and exit
#   --validate               validate the current host-config and exit
#   -h, --help               this help

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/host-config-templates"
HELPER="$SCRIPT_DIR/lib/host-config.py"

# shellcheck source=lib/robot-id.sh
. "$SCRIPT_DIR/lib/robot-id.sh"

OUTPUT_FILE="${OUTPUT_FILE:-/etc/phantomos/host-config.yaml}"
FROM_TEMPLATE=""
YES=0
SHOW=0
VALIDATE=0

# ---- arg parsing --------------------------------------------------------

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-template) FROM_TEMPLATE="${2:-}"; shift 2 ;;
    --output)        OUTPUT_FILE="${2:-}"; shift 2 ;;
    --no-write)      shift ;;  # accepted but no-op; default behavior
    -y|--yes)        YES=1; shift ;;
    --show)          SHOW=1; shift ;;
    --validate)      VALIDATE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ---- helpers ------------------------------------------------------------

C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_RED=$'\033[31m'
C_RESET=$'\033[0m'

[ -t 1 ] || { C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_RED=""; C_RESET=""; }

heading() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }
hint()    { printf '%s  %s%s\n' "$C_DIM" "$1" "$C_RESET"; }
example() { printf '%s    e.g. %s%s\n' "$C_DIM" "$1" "$C_RESET"; }
ok()      { printf '%s  ✓ %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn()    { printf '%s  ! %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
err()     { printf '%s  ✗ %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }

die() { err "$1"; exit "${2:-1}"; }

# Read a value from stdin with a default. Pressing enter accepts the
# default. `?` triggers a help message (passed in $4). Validators get
# the value as $1; non-zero return rejects and re-prompts.
ask() {
  local prompt="$1"; local default="${2:-}"; local help="${3:-}"; local validator="${4:-}"
  local input value

  while :; do
    if [ -n "$default" ]; then
      printf '  %s%s%s [%s]: ' "$C_CYAN" "$prompt" "$C_RESET" "$default" >&2
    else
      printf '  %s%s%s: ' "$C_CYAN" "$prompt" "$C_RESET" >&2
    fi

    if [ "$YES" = 1 ]; then
      input=""
      printf '%s\n' "$default" >&2
    else
      IFS= read -r input || input=""
    fi

    if [ "$input" = "?" ] && [ -n "$help" ]; then
      printf '%s%s%s\n' "$C_DIM" "$help" "$C_RESET" >&2
      continue
    fi

    value="${input:-$default}"

    if [ -n "$validator" ]; then
      if ! "$validator" "$value"; then
        continue
      fi
    fi

    printf '%s' "$value"
    return 0
  done
}

confirm() {
  local prompt="$1"; local default="${2:-y}"; local input
  while :; do
    if [ "$default" = "y" ]; then
      printf '  %s%s%s [Y/n]: ' "$C_CYAN" "$prompt" "$C_RESET"
    else
      printf '  %s%s%s [y/N]: ' "$C_CYAN" "$prompt" "$C_RESET"
    fi
    if [ "$YES" = 1 ]; then
      input=""
      printf '\n'
    else
      IFS= read -r input || input=""
    fi
    input="${input:-$default}"
    case "$input" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
    esac
  done
}

# ---- show / validate shortcuts -----------------------------------------

if [ "$SHOW" = 1 ]; then
  if [ ! -r "$OUTPUT_FILE" ]; then
    err "$OUTPUT_FILE not present"
    exit 1
  fi
  printf '%s%s%s\n' "$C_BOLD" "$OUTPUT_FILE:" "$C_RESET"
  cat "$OUTPUT_FILE"
  exit 0
fi

if [ "$VALIDATE" = 1 ]; then
  if [ ! -r "$OUTPUT_FILE" ]; then
    err "$OUTPUT_FILE not present"
    exit 1
  fi
  python3 "$HELPER" "$OUTPUT_FILE" validate
  exit $?
fi

# ---- defaults discovery -------------------------------------------------

# Pre-fill priority:
#   1. --from-template <robot>
#   2. existing /etc/phantomos/host-config.yaml
#   3. host-config-templates/<hostname>/host-config.yaml
#   4. host-config-templates/_template/host-config.yaml
seed_path=""
if [ -n "$FROM_TEMPLATE" ]; then
  seed_path="$TEMPLATES_DIR/$FROM_TEMPLATE/host-config.yaml"
  [ -r "$seed_path" ] || die "template not found: $seed_path"
elif [ -r "$OUTPUT_FILE" ]; then
  seed_path="$OUTPUT_FILE"
else
  hn="$(hostname 2>/dev/null || true)"
  if [ -n "$hn" ] && [ -r "$TEMPLATES_DIR/$hn/host-config.yaml" ]; then
    seed_path="$TEMPLATES_DIR/$hn/host-config.yaml"
  elif [ -r "$TEMPLATES_DIR/_template/host-config.yaml" ]; then
    seed_path="$TEMPLATES_DIR/_template/host-config.yaml"
  fi
fi

# Read seed values via the helper. Empty strings if seed has no value.
seed_robot=""; seed_ai=""; seed_images_yaml=""
if [ -n "$seed_path" ]; then
  seed_robot="$(python3 "$HELPER" "$seed_path" get robot 2>/dev/null || true)"
  seed_ai="$(python3 "$HELPER" "$seed_path" get aiPcUrl 2>/dev/null || true)"
  # Pull the images: block out by chopping everything before the
  # first 'images:' line. Crude but adequate — seed files come from
  # this repo or were last written by us.
  seed_images_yaml="$(awk '/^images:/{flag=1} flag' "$seed_path" || true)"
fi

# ---- validators ---------------------------------------------------------

validate_robot() {
  local v="$1"
  local lower
  lower="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$v" ]; then err "robot name required"; return 1; fi
  if [ ! -d "$REPO_ROOT/manifests/robots/$lower" ]; then
    local available
    available="$(ls -1 "$REPO_ROOT/manifests/robots/" 2>/dev/null | tr '\n' ' ')"
    err "no overlay manifests/robots/$lower/ — available: ${available:-<none>}"
    return 1
  fi
  return 0
}

validate_url() {
  local v="$1"
  case "$v" in
    http://*|https://*) return 0 ;;
    *) err "URL must start with http:// or https:// (got: $v)"; return 1 ;;
  esac
}

# ---- wizard -------------------------------------------------------------

heading "phantom-os host configuration"
hint "Single per-host config file: $OUTPUT_FILE"
hint "Edits below will be written to that path. Press '?' on any prompt for help."
if [ -n "$seed_path" ] && [ "$seed_path" != "$OUTPUT_FILE" ]; then
  hint "Pre-filling defaults from: $seed_path"
elif [ "$seed_path" = "$OUTPUT_FILE" ]; then
  hint "Editing existing $OUTPUT_FILE — current values shown as defaults"
fi

# --- robot ---
heading "robot identity"
hint "Must match a directory under manifests/robots/ on the deployed branch."
hint "Available: $(ls -1 "$REPO_ROOT/manifests/robots/" 2>/dev/null | tr '\n' ' ')"
example "mk09, ak-007, mk11000010"
robot_default="$seed_robot"
if [ -z "$robot_default" ]; then
  hn="$(hostname 2>/dev/null || true)"
  if [ -n "$hn" ] && [ -d "$REPO_ROOT/manifests/robots/$(printf '%s' "$hn" | tr '[:upper:]' '[:lower:]')" ]; then
    robot_default="$hn"
  fi
fi
robot="$(ask "robot" "$robot_default" "Identifier matching manifests/robots/<name>/. Lowercase preferred." validate_robot)"
robot="$(printf '%s' "$robot" | tr '[:upper:]' '[:lower:]')"
ok "robot = $robot"

# --- AI PC URL ---
heading "AI PC pairing"
hint "Tailscale URL of the AI PC paired with this robot. operator-ui talks to it."
example "http://100.124.202.97:5000"
ai_default="$seed_ai"
ai_pc_url="$(ask "aiPcUrl" "$ai_default" "Full URL with scheme + port. Tailscale IP recommended." validate_url)"
ok "aiPcUrl = $ai_pc_url"

# --- images ---
heading "image tag overrides"
hint "Per-host kustomize.images entries injected into the live Argo Application."
hint "These override anything in manifests/robots/<robot>/kustomization.yaml's"
hint "images: block. Skip this section to leave overlay defaults in effect."

inject_images=1
if [ -z "$seed_images_yaml" ]; then
  if ! confirm "Add image tag overrides? (recommended for production robots)" "y"; then
    inject_images=0
  fi
else
  hint "Defaults from seed:"
  printf '%s%s%s\n' "$C_DIM" "$(printf '%s\n' "$seed_images_yaml" | sed 's/^/    /')" "$C_RESET"
  if ! confirm "Use these as the starting point?" "y"; then
    if ! confirm "Skip image overrides entirely?" "n"; then
      die "aborted — re-run and accept defaults or pick --from-template <robot>"
    fi
    inject_images=0
  fi
fi

# Image entries to write. We collect them as parallel arrays
# (name + tag) and emit at the end. The seed images go in first, then
# the operator can edit each one.
declare -a img_names
declare -a img_tags

if [ "$inject_images" = 1 ]; then
  # Parse seed images into the arrays.
  if [ -n "$seed_images_yaml" ]; then
    while IFS= read -r line; do
      # accept lines like "  - name: foo" / "    newTag: bar"
      case "$line" in
        *"- name:"*)
          img_names+=("${line#*- name:}")
          img_names[-1]="$(printf '%s' "${img_names[-1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          img_tags+=("")
          ;;
        *newTag:*)
          if [ "${#img_tags[@]}" -gt 0 ]; then
            tag="${line#*newTag:}"
            tag="$(printf '%s' "$tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            img_tags[$((${#img_tags[@]}-1))]="$tag"
          fi
          ;;
      esac
    done <<< "$seed_images_yaml"
  fi

  if [ "${#img_names[@]}" -eq 0 ]; then
    # No seed images — start from the canonical fleet set.
    img_names+=("localhost:5443/positronic-control"); img_tags+=("")
    img_names+=("localhost:5443/phantom-models");      img_tags+=("")
    img_names+=("foundationbot/argus.operator-ui");    img_tags+=("")
  fi

  echo
  hint "Press enter to keep each tag, or type a new value."
  example "0.2.44-production-cu130 (positronic-control)"
  example "2026-04-30 (phantom-models — date-stamped)"
  example "585e58803318f5366d793986ad3e6129538b8a81 (operator-ui — git SHA)"
  for i in "${!img_names[@]}"; do
    new_tag="$(ask "${img_names[$i]} tag" "${img_tags[$i]}" "Tag this robot should pull. Empty to skip this image.")"
    img_tags[$i]="$new_tag"
  done
fi

# ---- render -------------------------------------------------------------

tmp=""
trap 'rm -f "$tmp"' EXIT
tmp="$(mktemp)"
{
  printf '# Generated by scripts/configure-host.sh on %s\n' "$(date -u +%FT%TZ)"
  printf '# Edit by re-running configure-host.sh, or hand-edit and run\n'
  printf '# bootstrap-robot.sh to apply.\n'
  printf 'robot: %s\n' "$robot"
  printf 'aiPcUrl: %s\n' "$ai_pc_url"
  if [ "$inject_images" = 1 ]; then
    printf 'images:\n'
    for i in "${!img_names[@]}"; do
      [ -z "${img_tags[$i]}" ] && continue
      printf '  - name: %s\n' "${img_names[$i]}"
      printf '    newTag: %s\n' "${img_tags[$i]}"
    done
  fi
} > "$tmp"

heading "review"
sed 's/^/    /' "$tmp"

if ! python3 "$HELPER" "$tmp" validate >/dev/null; then
  err "validation failed — re-running"
  python3 "$HELPER" "$tmp" validate >&2 || true
  exit 1
fi
ok "validates"

if ! confirm "Write to $OUTPUT_FILE?" "y"; then
  warn "not writing. Tempfile preserved at: $tmp"
  trap - EXIT
  exit 0
fi

# Need root for the canonical /etc/phantomos location, but allow custom
# paths to be written by the invoking user.
case "$OUTPUT_FILE" in
  /etc/phantomos/*)
    if [ "$(id -u)" -ne 0 ]; then
      die "must be root to write $OUTPUT_FILE — re-run with sudo or use --output <path>"
    fi
    ;;
esac

mkdir -p "$(dirname "$OUTPUT_FILE")"
install -m 0644 "$tmp" "$OUTPUT_FILE"
ok "wrote $OUTPUT_FILE"

if confirm "Run bootstrap-robot.sh now?" "n"; then
  exec bash "$SCRIPT_DIR/bootstrap-robot.sh"
fi
