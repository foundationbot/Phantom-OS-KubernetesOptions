#!/usr/bin/env bash
# configure-host.sh — interactive editor for /etc/phantomos/host-config.yaml.
#
# Walks the operator through the per-host config fields (robot identity,
# AI PC URL, image tag overrides) with defaults and examples, then
# writes the result. Companion to scripts/bootstrap-robot.sh — run this
# once on a fresh machine, then bootstrap-robot.sh consumes the file.
#
# Usage:
#   sudo bash scripts/configure-host.sh                  # full wizard
#   sudo bash scripts/configure-host.sh --from-template ~/fleet-config/mk09
#                                                         # pre-fill from an
#                                                         # operator-supplied
#                                                         # template tree
#   sudo bash scripts/configure-host.sh --output /tmp/hc.yaml --no-write
#                                                         # render to a custom
#                                                         # path without root
#   sudo bash scripts/configure-host.sh --show            # print current
#                                                         # host-config
#   sudo bash scripts/configure-host.sh --validate        # validate current
#                                                         # host-config
#
# The repo only ships host-config-templates/_template/ as a generic
# schema. Per-robot values live on each device under /etc/phantomos/
# (or, eventually, in the fleet control plane). To pre-fill the wizard
# from another robot's known-good values, either pass --from-template
# pointing at an operator-supplied template tree OR copy that robot's
# /etc/phantomos/host-config.yaml in advance and let the wizard pick it
# up as the existing seed.
#
# Flags:
#   --from-template <name|path>  pre-fill from a template tree. If the
#                                value is a plain name (no '/'), looks
#                                under host-config-templates/<name>/.
#                                Otherwise treats the value as a path.
#   --output <path>              target file (default: /etc/phantomos/host-config.yaml)
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
        # In --yes mode there's no way to recover from a bad default,
        # so exit instead of looping forever on the same invalid value.
        if [ "$YES" = 1 ]; then
          err "--yes: default $value failed validation; aborting"
          exit 1
        fi
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
  # Two forms:
  #   --from-template mk09             -> host-config-templates/mk09/host-config.yaml
  #                                       (no longer ships in the repo, but an
  #                                       operator-supplied tree under
  #                                       host-config-templates/ would still match)
  #   --from-template /path/to/dir     -> /path/to/dir/host-config.yaml
  #   --from-template /path/to/file.yaml -> use directly
  if [ -d "$FROM_TEMPLATE" ]; then
    seed_path="$FROM_TEMPLATE/host-config.yaml"
  elif [ -f "$FROM_TEMPLATE" ]; then
    seed_path="$FROM_TEMPLATE"
  else
    seed_path="$TEMPLATES_DIR/$FROM_TEMPLATE/host-config.yaml"
  fi
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
seed_robot=""; seed_ai=""; seed_target_rev=""; seed_production=""; seed_images_yaml=""
seed_dev_source=""; seed_dev_privileged="false"
declare -a seed_dev_mount_hosts
declare -a seed_dev_mount_containers

if [ -n "$seed_path" ]; then
  seed_robot="$(python3 "$HELPER" "$seed_path" get robot 2>/dev/null || true)"
  seed_ai="$(python3 "$HELPER" "$seed_path" get aiPcUrl 2>/dev/null || true)"
  seed_target_rev="$(python3 "$HELPER" "$seed_path" get targetRevision 2>/dev/null || true)"
  seed_production="$(python3 "$HELPER" "$seed_path" get production 2>/dev/null || true)"
  # Pull the images: block out by chopping everything before the
  # first 'images:' line. Crude but adequate — seed files come from
  # this repo or were last written by us.
  # Pull the images: block — start at 'images:' line, stop at the
  # next top-level key (anything matching ^[a-zA-Z] that isn't
  # 'images:' itself).
  seed_images_yaml="$(awk '
    /^images:/         { flag=1; print; next }
    flag && /^[a-zA-Z]/{ exit }
    flag               { print }
  ' "$seed_path" || true)"

  # devMode harvest. Inline Python so we don't have to teach the
  # helper script every accessor.
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      source)     seed_dev_source="$a" ;;
      privileged) seed_dev_privileged="$a" ;;
      mount)      seed_dev_mount_hosts+=("$a"); seed_dev_mount_containers+=("$b") ;;
    esac
  done < <(python3 - "$seed_path" <<'PY'
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
pos = ((cfg.get("devMode") or {}).get("positronic-control") or {})
src = pos.get("source") or ""
if src:
    print(f"source\t{src}\t")
print(f"privileged\t{'true' if pos.get('privileged') else 'false'}\t")
for m in pos.get("mounts") or []:
    if isinstance(m, dict) and m.get("host") and m.get("container"):
        print(f"mount\t{m['host']}\t{m['container']}")
PY
)
fi

# ---- validators ---------------------------------------------------------

validate_robot() {
  local v="$1"
  local lower
  lower="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$v" ]; then err "robot name required"; return 1; fi
  # DNS-1123: lowercase alphanumeric + hyphens, 1..63 chars,
  # bookended by alphanumeric. The name flows into Argo Application
  # metadata.name (e.g. phantomos-mk09-core), which Kubernetes
  # requires to be DNS-1123. There is no filesystem check —
  # robots are no longer tied to a manifests/robots/<name>/ tree.
  if ! printf '%s' "$lower" | grep -Eq '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'; then
    err "robot name $v is not DNS-1123 (lowercase alnum + hyphens, 1..63 chars, bookended by alnum)"
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

validate_abs_path() {
  local v="$1"
  if [ -z "$v" ]; then err "path required"; return 1; fi
  case "$v" in
    "~"*) err "'~' is not allowed (bootstrap runs as root). Use the absolute path."; return 1 ;;
    /*) ;;
    *) err "must be an absolute path (got: $v)"; return 1 ;;
  esac
  if [ ! -d "$v" ]; then
    warn "$v does not exist on this host (will be auto-created on first pod start via DirectoryOrCreate)"
  fi
  return 0
}

# Resolve the invoking user's home dir so we can suggest sane mount
# defaults. When run via sudo, $HOME is /root — useless for mount
# defaults — so prefer SUDO_USER's home.
invoking_home="${HOME:-/root}"
if [ -n "${SUDO_USER:-}" ]; then
  if uh="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" && [ -n "$uh" ]; then
    invoking_home="$uh"
  fi
fi

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
hint "DNS-1123 label: lowercase alphanumeric + hyphens, 1..63 chars."
hint "Used in Argo Application names (phantomos-<robot>-core, ...)."
example "mk09, ak-007, mk11000010"
robot_default="$seed_robot"
if [ -z "$robot_default" ]; then
  hn="$(hostname 2>/dev/null || true)"
  hn_lower="$(printf '%s' "${hn:-}" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$hn_lower" ] && printf '%s' "$hn_lower" \
       | grep -Eq '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'; then
    robot_default="$hn_lower"
  fi
fi
robot="$(ask "robot" "$robot_default" "DNS-1123: lowercase alnum + hyphens, 1..63 chars, bookended by alnum." validate_robot)"
robot="$(printf '%s' "$robot" | tr '[:upper:]' '[:lower:]')"
ok "robot = $robot"

# --- AI PC URL ---
heading "AI PC pairing"
hint "Tailscale URL of the AI PC paired with this robot. operator-ui talks to it."
example "http://100.124.202.97:5000"
ai_default="$seed_ai"
ai_pc_url="$(ask "aiPcUrl" "$ai_default" "Full URL with scheme + port. Tailscale IP recommended." validate_url)"
ok "aiPcUrl = $ai_pc_url"

# --- targetRevision ---
heading "ArgoCD target revision"
hint "Branch / tag / SHA the per-host ArgoCD Application should track."
hint "'main' is the default for production robots; use a feature branch when"
hint "testing changes before merge."
example "main, feat/mk09-positronic-0.2.44-production"
target_default="${seed_target_rev:-main}"
target_revision="$(ask "targetRevision" "$target_default" "Any valid git ref reachable from the configured repo URL.")"
ok "targetRevision = $target_revision"

# --- production / selfHeal ---
heading "production mode (ArgoCD selfHeal)"
hint "When ON, ArgoCD auto-reverts manual cluster edits to the deployed"
hint "resources (selfHeal: true). Useful in steady state. PAINFUL during"
hint "incidents — anything you 'kubectl edit' will be silently undone."
hint "Recommended: ON for production robots, OFF for dev/debug machines."
production="false"
prod_default="n"
case "$seed_production" in true|True) prod_default="y" ;; esac
if confirm "Production mode (selfHeal)?" "$prod_default"; then
  production="true"
  warn "selfHeal enabled — manual kubectl edits to deployed resources will revert"
fi
ok "production = $production"

# --- images ---
heading "image tag overrides"
hint "Per-host kustomize.images entries injected into the live Argo Application."
hint "These override anything in manifests/stacks/<stack>/ image references."
hint "Skip this section to leave overlay defaults in effect."

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
img_names=()
img_tags=()

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

# --- devMode (positronic-control hostPath mounts) ---
heading "dev mode (positronic-control hostPath mounts)"
hint "Optional. Bind-mounts your local source tree + data dirs into the"
hint "positronic-control pod so code changes are visible without rebuilding."
hint "Production robots should leave this OFF."

declare -a dev_mount_hosts
declare -a dev_mount_containers
dev_enabled=0
dev_source=""
dev_privileged="false"

# If the seed already has devMode, default to "yes, edit existing".
# Otherwise default to "no" so production bringups don't accidentally
# enable host mounts.
dev_default_enable="n"
if [ -n "$seed_dev_source" ] || [ "${#seed_dev_mount_hosts[@]}" -gt 0 ]; then
  hint "Seed has an existing devMode block — defaulting to keep-and-edit."
  dev_default_enable="y"
fi

if confirm "Enable dev-mode hostPath mounts for positronic-control?" "$dev_default_enable"; then
  dev_enabled=1

  # source path — single host dir mounted at /src
  hint "Single source-tree path (mounted at /src in the pod)."
  example "$invoking_home/development/foundation/positronic_control"
  dev_source_default="$seed_dev_source"
  if [ -z "$dev_source_default" ]; then
    dev_source_default="$invoking_home/development/foundation/positronic_control"
  fi
  dev_source="$(ask "source" "$dev_source_default" "Absolute host path (no '~'). Mounted at /src." validate_abs_path)"
  ok "source = $dev_source"

  # mounts — start from seed if any, else propose the canonical set
  if [ "${#seed_dev_mount_hosts[@]}" -gt 0 ]; then
    for i in "${!seed_dev_mount_hosts[@]}"; do
      dev_mount_hosts+=("${seed_dev_mount_hosts[$i]}")
      dev_mount_containers+=("${seed_dev_mount_containers[$i]}")
    done
    hint "Editing ${#dev_mount_hosts[@]} mounts from seed. Press enter to keep each, type 'd' to drop."
  else
    # canonical fleet dev mount set, mirrors development.docker-compose.yaml
    dev_mount_hosts+=("/data");                                  dev_mount_containers+=("/data")
    dev_mount_hosts+=("/data2");                                 dev_mount_containers+=("/data2")
    dev_mount_hosts+=("$invoking_home/recordings");              dev_mount_containers+=("/recordings")
    dev_mount_hosts+=("$invoking_home/trainground");             dev_mount_containers+=("/trainground")
    dev_mount_hosts+=("$invoking_home/.cache/torch/hub");        dev_mount_containers+=("/root/.cache/torch/hub")
    hint "Proposed standard mount set (matches development.docker-compose.yaml)."
    hint "Press enter to keep each pair, type 'd' to drop, or type a new path."
  fi

  declare -a kept_hosts
  declare -a kept_containers
  for i in "${!dev_mount_hosts[@]}"; do
    h="${dev_mount_hosts[$i]}"
    c="${dev_mount_containers[$i]}"
    new_host="$(ask "mount $((i+1)) host  -> $c" "$h" "Type 'd' to drop this mount, or press enter to keep.")"
    if [ "$new_host" = "d" ] || [ "$new_host" = "D" ]; then
      info "  dropped"
      continue
    fi
    if ! validate_abs_path "$new_host"; then
      warn "  skipping invalid path"
      continue
    fi
    new_container="$(ask "mount $((i+1)) container path" "$c" "Where this should appear inside the pod.")"
    kept_hosts+=("$new_host")
    kept_containers+=("$new_container")
  done

  # offer to add more
  while confirm "Add another mount?" "n"; do
    nh="$(ask "host path" "" "Absolute host path." validate_abs_path)"
    nc="$(ask "container path" "" "Absolute path inside the pod.")"
    kept_hosts+=("$nh")
    kept_containers+=("$nc")
  done

  dev_mount_hosts=()
  dev_mount_containers=()
  for i in "${!kept_hosts[@]}"; do
    dev_mount_hosts+=("${kept_hosts[$i]}")
    dev_mount_containers+=("${kept_containers[$i]}")
  done
  ok "${#dev_mount_hosts[@]} mounts kept"

  # privileged
  hint "privileged: true grants /dev passthrough and full host access."
  hint "Required if the pod opens /dev/* (USB, GPIO, /dev/shm with host quirks)."
  hint "DO NOT enable on production robots."
  priv_default="$seed_dev_privileged"
  [ -z "$priv_default" ] && priv_default="false"
  if [ "$priv_default" = "true" ]; then
    if confirm "privileged?" "y"; then
      dev_privileged="true"
      warn "privileged enabled — pod will run with /dev passthrough"
    fi
  else
    if confirm "privileged?" "n"; then
      dev_privileged="true"
      warn "privileged enabled — pod will run with /dev passthrough"
    fi
  fi
  ok "privileged = $dev_privileged"
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
  printf 'targetRevision: %s\n' "$target_revision"
  printf 'production: %s\n' "$production"
  if [ "$inject_images" = 1 ]; then
    # Count non-empty tags so we don't emit an empty `images:` header.
    nonempty=0
    for i in "${!img_names[@]}"; do
      [ -n "${img_tags[$i]}" ] && nonempty=$((nonempty + 1))
    done
    if [ "$nonempty" -gt 0 ]; then
      printf 'images:\n'
      for i in "${!img_names[@]}"; do
        [ -z "${img_tags[$i]}" ] && continue
        printf '  - name: %s\n' "${img_names[$i]}"
        printf '    newTag: %s\n' "${img_tags[$i]}"
      done
    fi
  fi
  if [ "$dev_enabled" = 1 ]; then
    printf 'devMode:\n'
    printf '  positronic-control:\n'
    [ -n "$dev_source" ] && printf '    source: %s\n' "$dev_source"
    if [ "${#dev_mount_hosts[@]}" -gt 0 ]; then
      printf '    mounts:\n'
      for i in "${!dev_mount_hosts[@]}"; do
        printf '      - {host: %s, container: %s}\n' \
          "${dev_mount_hosts[$i]}" "${dev_mount_containers[$i]}"
      done
    fi
    printf '    privileged: %s\n' "$dev_privileged"
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
