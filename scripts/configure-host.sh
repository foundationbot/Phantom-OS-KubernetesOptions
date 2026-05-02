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

heading() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET" >&2; }
hint()    { printf '%s  %s%s\n' "$C_DIM" "${1:-}" "$C_RESET" >&2; }
info()    { printf '  %s\n' "${1:-}" >&2; }
# All status helpers go to stderr so $(ask ...) captures only the
# user's value. ok/warn/info/example/heading/hint never end up inside
# the rendered YAML.
example() { printf '%s    e.g. %s%s\n' "$C_DIM" "$1" "$C_RESET" >&2; }
ok()      { printf '%s  ✓ %s%s\n' "$C_GREEN" "$1" "$C_RESET" >&2; }
warn()    { printf '%s  ! %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }
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
      printf '  %s%s%s [Y/n]: ' "$C_CYAN" "$prompt" "$C_RESET" >&2
    else
      printf '  %s%s%s [y/N]: ' "$C_CYAN" "$prompt" "$C_RESET" >&2
    fi
    if [ "$YES" = 1 ]; then
      input=""
      printf '\n' >&2
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
# Per-deployment seed values (populated below from either the new
# `deployments:` block or the legacy `devMode:` block during migration).
seed_pos_privileged="false"
declare -a seed_pos_mount_names
declare -a seed_pos_mount_hosts
declare -a seed_pos_mount_containers
declare -a seed_api_mount_names
declare -a seed_api_mount_hosts
declare -a seed_api_mount_containers
# Per-stack seed values. Empty string = "not set in seed" (use default).
seed_core_selfheal=""
seed_operator_enabled=""
seed_operator_selfheal=""

if [ -n "$seed_path" ]; then
  seed_robot="$(python3 "$HELPER" "$seed_path" get robot 2>/dev/null || true)"
  seed_ai="$(python3 "$HELPER" "$seed_path" get aiPcUrl 2>/dev/null || true)"
  seed_target_rev="$(python3 "$HELPER" "$seed_path" get targetRevision 2>/dev/null || true)"
  seed_production="$(python3 "$HELPER" "$seed_path" get production 2>/dev/null || true)"

  # Per-stack seed values (any of these may be empty).
  while IFS=$'\t' read -r kind name field val; do
    case "$kind:$name:$field" in
      stack:core:selfHeal)         seed_core_selfheal="$val" ;;
      stack:operator:enabled)      seed_operator_enabled="$val" ;;
      stack:operator:selfHeal)     seed_operator_selfheal="$val" ;;
    esac
  done < <(python3 - "$seed_path" <<'PY' 2>/dev/null
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
stacks = (cfg.get("stacks") or {}) if isinstance(cfg, dict) else {}
for name in ("core", "operator"):
    spec = stacks.get(name)
    if not isinstance(spec, dict):
        continue
    if "enabled" in spec:
        print(f"stack\t{name}\tenabled\t{'true' if spec['enabled'] else 'false'}")
    if "selfHeal" in spec:
        print(f"stack\t{name}\tselfHeal\t{'true' if spec['selfHeal'] else 'false'}")
PY
)
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

  # deployments harvest. Reads the new schema (`deployments.<name>.mounts`)
  # and falls back to the old schema (`devMode.<name>.{source,mounts}`)
  # when the operator hasn't migrated yet. Output is tab-separated:
  #   pos|api  privileged|mount  <fields...>
  while IFS=$'\t' read -r tgt kind a b c; do
    case "$tgt:$kind" in
      pos:privileged)  seed_pos_privileged="$a" ;;
      pos:mount)
        seed_pos_mount_names+=("$a")
        seed_pos_mount_hosts+=("$b")
        seed_pos_mount_containers+=("$c")
        ;;
      api:mount)
        seed_api_mount_names+=("$a")
        seed_api_mount_hosts+=("$b")
        seed_api_mount_containers+=("$c")
        ;;
    esac
  done < <(python3 - "$seed_path" <<'PY'
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
if not isinstance(cfg, dict):
    sys.exit(0)

def emit(target_short, name, host, container):
    print(f"{target_short}\tmount\t{name}\t{host}\t{container}")

deployments = cfg.get("deployments") or {}

# positronic-control
pos = deployments.get("positronic-control")
if isinstance(pos, dict):
    print(f"pos\tprivileged\t{'true' if pos.get('privileged') else 'false'}")
    for i, m in enumerate(pos.get("mounts") or []):
        if isinstance(m, dict) and m.get("host") and m.get("container"):
            emit("pos", m.get("name") or f"mount-{i}", m["host"], m["container"])
else:
    # Migration from legacy `devMode:` schema.
    legacy = ((cfg.get("devMode") or {}).get("positronic-control") or {})
    if isinstance(legacy, dict):
        print(f"pos\tprivileged\t{'true' if legacy.get('privileged') else 'false'}")
        if legacy.get("source"):
            emit("pos", "src", legacy["source"], "/src")
        for i, m in enumerate(legacy.get("mounts") or []):
            if isinstance(m, dict) and m.get("host") and m.get("container"):
                emit("pos", m.get("name") or f"legacy-{i}", m["host"], m["container"])

# phantomos-api-server
api = deployments.get("phantomos-api-server")
if isinstance(api, dict):
    for i, m in enumerate(api.get("mounts") or []):
        if isinstance(m, dict) and m.get("host") and m.get("container"):
            emit("api", m.get("name") or f"mount-{i}", m["host"], m["container"])
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

# --- stacks ---
heading "stack toggles"
hint "Each stack is a group of related Applications:"
hint "  core      registry, dma-video, positronic, phantomos-api-server,"
hint "            yovariable-server. ALWAYS ON — robot won't function without it."
hint "  operator  argus + nimbus (operator-ui, eg-server, mongodb, redis,"
hint "            postgres). Toggle off to remove the operator-facing surface."
hint
hint "Per-stack selfHeal is optional and overrides the global production"
hint "flag for that stack only. Most operators leave both unset."

# core: cannot be disabled. Optional selfHeal override.
core_selfheal="<unset>"
case "$seed_core_selfheal" in
  true)  core_selfheal="true" ;;
  false) core_selfheal="false" ;;
esac
hint
hint "core stack selfHeal:"
hint "  unset  -> follow global production: setting (currently $production)"
hint "  true   -> always selfHeal even if production is false"
hint "  false  -> never selfHeal even if production is true"
core_sh_default="$core_selfheal"
[ "$core_sh_default" = "<unset>" ] && core_sh_default=""
core_sh_input="$(ask "core.selfHeal (true|false|empty)" "$core_sh_default" "Empty = follow global production: flag.")"
case "$core_sh_input" in
  true|True)   core_selfheal="true" ;;
  false|False) core_selfheal="false" ;;
  "")          core_selfheal="<unset>" ;;
  *)
    err "core.selfHeal must be 'true', 'false', or empty — leaving unset"
    core_selfheal="<unset>"
    ;;
esac
ok "core.selfHeal = $core_selfheal"

# operator: enabled (default true), optional selfHeal override.
operator_enabled="true"
op_default="y"
case "$seed_operator_enabled" in false|False) op_default="n" ;; esac
if ! confirm "Enable operator stack (argus + nimbus)?" "$op_default"; then
  operator_enabled="false"
  info "operator stack will be removed from the cluster on next bootstrap"
fi
ok "operator.enabled = $operator_enabled"

operator_selfheal="<unset>"
if [ "$operator_enabled" = "true" ]; then
  case "$seed_operator_selfheal" in
    true)  operator_selfheal="true" ;;
    false) operator_selfheal="false" ;;
  esac
  hint
  hint "operator stack selfHeal: same semantics as core.selfHeal."
  op_sh_default="$operator_selfheal"
  [ "$op_sh_default" = "<unset>" ] && op_sh_default=""
  op_sh_input="$(ask "operator.selfHeal (true|false|empty)" "$op_sh_default" "Empty = follow global production: flag.")"
  case "$op_sh_input" in
    true|True)   operator_selfheal="true" ;;
    false|False) operator_selfheal="false" ;;
    "")          operator_selfheal="<unset>" ;;
    *)
      err "operator.selfHeal must be 'true', 'false', or empty — leaving unset"
      operator_selfheal="<unset>"
      ;;
  esac
  ok "operator.selfHeal = $operator_selfheal"
fi

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
  printf '%s%s%s\n' "$C_DIM" "$(printf '%s\n' "$seed_images_yaml" | sed 's/^/    /')" "$C_RESET" >&2
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

  # Canonical fleet image set with sensible default tags. Schema-evolution
  # safe: any new entry here is automatically offered to existing
  # host-configs as a missing-from-seed prompt, so adding an image to
  # the fleet doesn't require operators to hand-edit their host-config.
  declare -a canonical_names=(
    "localhost:5443/positronic-control"
    "localhost:5443/phantom-models"
    "foundationbot/argus.operator-ui"
    "foundationbot/dma-ethercat"
  )
  declare -a canonical_default_tags=(
    ""
    ""
    ""
    "main-latest-aarch64"
  )

  # Append any canonical name missing from the seed. Existing seed
  # entries (and their values) are preserved; missing ones get the
  # canonical default tag so the operator can press enter to accept.
  for c_i in "${!canonical_names[@]}"; do
    c_name="${canonical_names[$c_i]}"
    found=0
    for i in "${!img_names[@]}"; do
      if [ "${img_names[$i]}" = "$c_name" ]; then found=1; break; fi
    done
    if [ "$found" = 0 ]; then
      img_names+=("$c_name")
      img_tags+=("${canonical_default_tags[$c_i]}")
    fi
  done

  echo
  hint "Press enter to keep each tag, or type a new value."
  example "0.2.44-production-cu130 (positronic-control)"
  example "2026-04-30 (phantom-models — date-stamped)"
  example "585e58803318f5366d793986ad3e6129538b8a81 (operator-ui — git SHA)"
  example "main-latest-aarch64 (dma-ethercat — host arch matters)"
  for i in "${!img_names[@]}"; do
    new_tag="$(ask "${img_names[$i]} tag" "${img_tags[$i]}" "Tag this robot should pull. Empty to skip this image.")"
    img_tags[$i]="$new_tag"
  done
fi

# --- deployments: positronic-control mounts ---------------------------
heading "deployments: positronic-control mounts"
hint "Per-host hostPath mounts injected into the positronic-control pod."
hint "The base manifest carries only kernel mounts (/dev, /dev/shm, /tmp);"
hint "everything else — source checkout, data partitions, recordings,"
hint "torch cache, training data — comes from this list."

# Final state:
declare -a pos_mount_names
declare -a pos_mount_hosts
declare -a pos_mount_containers
pos_privileged="false"

# Production preset — paths a real production robot needs. Configurable
# but team-canonical. /data + /data2 = production data partitions;
# /root/recordings = dma-video write target (matches the recordings PV
# in nimbus); /data/torch = torch hub cache.
declare -a preset_prod_names=(data data2 recordings torch-hub)
declare -a preset_prod_hosts=(/data /data2 /root/recordings /data/torch)
declare -a preset_prod_containers=(/data /data2 /recordings /root/.cache/torch/hub)

# Dev preset = production + source tree + IHMC config + trainground.
# These are the additional mounts only a developer's host has.
_dev_src_default="$invoking_home/development/foundation/positronic_control"
declare -a preset_dev_names=("${preset_prod_names[@]}"   src                    ihmc-config                                                   trainground)
declare -a preset_dev_hosts=("${preset_prod_hosts[@]}"   "$_dev_src_default"    "$_dev_src_default/workspace/.ihmc"                           "$invoking_home/trainground")
declare -a preset_dev_containers=("${preset_prod_containers[@]}" /src           /root/.ihmc                                                   /trainground)

# Decide a default preset based on what the seed has.
preset_default="production"
if [ "${#seed_pos_mount_names[@]}" -gt 0 ]; then
  preset_default="seed"
fi

hint
hint "Preset:"
hint "  seed       use the existing mount list from your host-config (if any)"
hint "  production data, data2, recordings, torch-hub                    (4 mounts)"
hint "  dev        production + src, ihmc-config, trainground            (7 mounts)"
hint "  none       no mounts (kernel-only pod)"
hint "  custom     start empty, add each mount by hand"
preset_choice="$(ask "preset" "$preset_default" "One of: seed | production | dev | none | custom")"

case "$preset_choice" in
  seed)
    if [ "${#seed_pos_mount_names[@]}" -eq 0 ]; then
      warn "seed has no positronic-control mounts; falling back to production preset"
      pos_mount_names=("${preset_prod_names[@]}")
      pos_mount_hosts=("${preset_prod_hosts[@]}")
      pos_mount_containers=("${preset_prod_containers[@]}")
    else
      pos_mount_names=("${seed_pos_mount_names[@]}")
      pos_mount_hosts=("${seed_pos_mount_hosts[@]}")
      pos_mount_containers=("${seed_pos_mount_containers[@]}")
    fi
    ;;
  production)
    pos_mount_names=("${preset_prod_names[@]}")
    pos_mount_hosts=("${preset_prod_hosts[@]}")
    pos_mount_containers=("${preset_prod_containers[@]}")
    ;;
  dev)
    pos_mount_names=("${preset_dev_names[@]}")
    pos_mount_hosts=("${preset_dev_hosts[@]}")
    pos_mount_containers=("${preset_dev_containers[@]}")
    ;;
  none)
    pos_mount_names=()
    pos_mount_hosts=()
    pos_mount_containers=()
    ;;
  custom|*)
    pos_mount_names=()
    pos_mount_hosts=()
    pos_mount_containers=()
    ;;
esac

# Edit each pre-filled mount in place; allow drop with 'd'.
declare -a kept_names kept_hosts kept_containers
for i in "${!pos_mount_names[@]}"; do
  n="${pos_mount_names[$i]}"
  h="${pos_mount_hosts[$i]}"
  c="${pos_mount_containers[$i]}"
  new_host="$(ask "$(printf 'mount %d  %-13s host  -> %s' "$((i+1))" "[$n]" "$c")" "$h" "Press enter to keep, 'd' to drop, or type a new path.")"
  if [ "$new_host" = "d" ] || [ "$new_host" = "D" ]; then
    info "  dropped"
    continue
  fi
  if ! validate_abs_path "$new_host"; then
    warn "  skipping invalid path"
    continue
  fi
  new_container="$(ask "mount $((i+1)) container path" "$c" "")"
  kept_names+=("$n")
  kept_hosts+=("$new_host")
  kept_containers+=("$new_container")
done
while confirm "Add another mount?" "n"; do
  nn="$(ask "volume name" "" "DNS-1123 short name (e.g. extra-data, dev-config)")"
  nh="$(ask "host path" "" "Absolute host path." validate_abs_path)"
  nc="$(ask "container path" "" "Absolute path inside the pod.")"
  kept_names+=("$nn")
  kept_hosts+=("$nh")
  kept_containers+=("$nc")
done
pos_mount_names=("${kept_names[@]:-}")
pos_mount_hosts=("${kept_hosts[@]:-}")
pos_mount_containers=("${kept_containers[@]:-}")
# Bash's :- substitution above leaves a single empty element when
# the source array is empty; strip it.
if [ "${#pos_mount_names[@]}" -eq 1 ] && [ -z "${pos_mount_names[0]}" ]; then
  pos_mount_names=(); pos_mount_hosts=(); pos_mount_containers=()
fi
ok "${#pos_mount_names[@]} positronic-control mounts kept"

# Privileged toggle.
hint
hint "privileged: true grants /dev passthrough and full host access."
hint "DO NOT enable on production robots."
priv_default="n"
[ "$seed_pos_privileged" = "true" ] && priv_default="y"
if confirm "privileged?" "$priv_default"; then
  pos_privileged="true"
  warn "privileged enabled — pod will run with /dev passthrough"
fi
ok "positronic-control.privileged = $pos_privileged"

# --- deployments: phantomos-api-server mounts -------------------------
heading "deployments: phantomos-api-server mounts (optional)"
hint "phantomos-api-server runs without any extra hostPath mounts by"
hint "default. Enable this only if you need to expose on-host project"
hint "trees (operator-ui compose, phantom scripts) into the api pod."

declare -a api_mount_names
declare -a api_mount_hosts
declare -a api_mount_containers

api_default="n"
[ "${#seed_api_mount_names[@]}" -gt 0 ] && api_default="y"
if confirm "Configure phantomos-api-server mounts?" "$api_default"; then
  if [ "${#seed_api_mount_names[@]}" -gt 0 ]; then
    api_mount_names=("${seed_api_mount_names[@]}")
    api_mount_hosts=("${seed_api_mount_hosts[@]}")
    api_mount_containers=("${seed_api_mount_containers[@]}")
    hint "Editing ${#api_mount_names[@]} mounts from seed."
  fi
  declare -a api_kept_names api_kept_hosts api_kept_containers
  for i in "${!api_mount_names[@]}"; do
    n="${api_mount_names[$i]}"
    h="${api_mount_hosts[$i]}"
    c="${api_mount_containers[$i]}"
    new_host="$(ask "$(printf 'mount %d  %-13s host  -> %s' "$((i+1))" "[$n]" "$c")" "$h" "Press enter to keep, 'd' to drop.")"
    if [ "$new_host" = "d" ] || [ "$new_host" = "D" ]; then continue; fi
    if ! validate_abs_path "$new_host"; then warn "  skipping invalid path"; continue; fi
    new_container="$(ask "mount $((i+1)) container path" "$c" "")"
    api_kept_names+=("$n")
    api_kept_hosts+=("$new_host")
    api_kept_containers+=("$new_container")
  done
  while confirm "Add another phantomos-api-server mount?" "n"; do
    nn="$(ask "volume name" "" "DNS-1123 short name")"
    nh="$(ask "host path" "" "Absolute host path." validate_abs_path)"
    nc="$(ask "container path" "" "Absolute path inside the api container.")"
    api_kept_names+=("$nn")
    api_kept_hosts+=("$nh")
    api_kept_containers+=("$nc")
  done
  api_mount_names=("${api_kept_names[@]:-}")
  api_mount_hosts=("${api_kept_hosts[@]:-}")
  api_mount_containers=("${api_kept_containers[@]:-}")
  if [ "${#api_mount_names[@]}" -eq 1 ] && [ -z "${api_mount_names[0]}" ]; then
    api_mount_names=(); api_mount_hosts=(); api_mount_containers=()
  fi
fi
ok "${#api_mount_names[@]} phantomos-api-server mounts kept"

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

  # Stacks block — emit only fields the operator explicitly set, so
  # the file stays close to the schema defaults and changes diff well.
  emit_stacks=0
  if [ "$core_selfheal" != "<unset>" ] \
     || [ "$operator_enabled" != "true" ] \
     || [ "$operator_selfheal" != "<unset>" ]; then
    emit_stacks=1
  fi
  if [ "$emit_stacks" = 1 ]; then
    printf 'stacks:\n'
    if [ "$core_selfheal" != "<unset>" ]; then
      printf '  core:\n'
      printf '    selfHeal: %s\n' "$core_selfheal"
    fi
    if [ "$operator_enabled" != "true" ] || [ "$operator_selfheal" != "<unset>" ]; then
      printf '  operator:\n'
      [ "$operator_enabled" != "true" ] && printf '    enabled: %s\n' "$operator_enabled"
      [ "$operator_selfheal" != "<unset>" ] && printf '    selfHeal: %s\n' "$operator_selfheal"
    fi
  fi

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
  # deployments block: emit only entries the operator explicitly
  # configured. Empty list = no patch injection for that deployment.
  if [ "${#pos_mount_names[@]}" -gt 0 ] || [ "$pos_privileged" = "true" ] \
     || [ "${#api_mount_names[@]}" -gt 0 ]; then
    printf 'deployments:\n'
    if [ "${#pos_mount_names[@]}" -gt 0 ] || [ "$pos_privileged" = "true" ]; then
      printf '  positronic-control:\n'
      [ "$pos_privileged" = "true" ] && printf '    privileged: true\n'
      if [ "${#pos_mount_names[@]}" -gt 0 ]; then
        printf '    mounts:\n'
        for i in "${!pos_mount_names[@]}"; do
          printf '      - {name: %s, host: %s, container: %s}\n' \
            "${pos_mount_names[$i]}" "${pos_mount_hosts[$i]}" "${pos_mount_containers[$i]}"
        done
      fi
    fi
    if [ "${#api_mount_names[@]}" -gt 0 ]; then
      printf '  phantomos-api-server:\n'
      printf '    mounts:\n'
      for i in "${!api_mount_names[@]}"; do
        printf '      - {name: %s, host: %s, container: %s}\n' \
          "${api_mount_names[$i]}" "${api_mount_hosts[$i]}" "${api_mount_containers[$i]}"
      done
    fi
  fi
} > "$tmp"

heading "review"
sed 's/^/    /' "$tmp" >&2

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
