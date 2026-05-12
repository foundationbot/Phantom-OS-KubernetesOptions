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
#   --auto-images            opt into automatic image-override resolution from
#                            the bundle manifest (default ON when the bundle
#                            manifest is present and parses; OFF otherwise).
#                            With --auto-images, the four canonical-container
#                            image prompts are skipped — refs come straight
#                            from seed → bundle → section-A precedence.
#   --no-auto-images         force interactive image prompts (overrides the
#                            default ON behavior). Each prompt is pre-filled
#                            with the resolved precedence value.
#   --show                   print the current host-config and exit
#   --validate               validate the current host-config and exit
#   -h, --help               this help
#
# Environment:
#   PHANTOMOS_AUTO_IMAGES=1  equivalent to --auto-images
#   PHANTOMOS_AUTO_IMAGES=0  equivalent to --no-auto-images

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

# Auto-images mode: -1 = unset (use bundle-presence default), 0 = off, 1 = on.
# CLI flags (--auto-images / --no-auto-images) take precedence over the
# PHANTOMOS_AUTO_IMAGES env var; both override the bundle-presence default.
AUTO_IMAGES=-1
case "${PHANTOMOS_AUTO_IMAGES:-}" in
  1) AUTO_IMAGES=1 ;;
  0) AUTO_IMAGES=0 ;;
  "") ;;
  *) printf 'warning: PHANTOMOS_AUTO_IMAGES=%s ignored (expected 0 or 1)\n' \
       "$PHANTOMOS_AUTO_IMAGES" >&2 ;;
esac

# ---- arg parsing --------------------------------------------------------

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-template)   FROM_TEMPLATE="${2:-}"; shift 2 ;;
    --output)          OUTPUT_FILE="${2:-}"; shift 2 ;;
    --no-write)        shift ;;  # accepted but no-op; default behavior
    -y|--yes)          YES=1; shift ;;
    --auto-images)     AUTO_IMAGES=1; shift ;;
    --no-auto-images)  AUTO_IMAGES=0; shift ;;
    --show)            SHOW=1; shift ;;
    --validate)        VALIDATE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
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

# Detect the network interface used to reach the default IPv4 gateway,
# and its primary IPv4 address. Prints "<iface>\t<ip>" on success;
# returns non-zero with no output on failure (no default route, no
# IPv4 on the interface, missing `ip` tool, etc.). Used by the AI PC
# pairing wizard step's "auto-detect" option.
detect_gateway_iface_ip() {
  command -v ip >/dev/null 2>&1 || return 1
  local iface ip4
  iface=$(ip -4 route show default 2>/dev/null \
            | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [ -n "$iface" ] || return 1
  ip4=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
          | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$ip4" ] || return 1
  printf '%s\t%s\n' "$iface" "$ip4"
}

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

# ---- bundle manifest reader --------------------------------------------

# Path to the bundle manifest sidecar written by the image .deb (RFC 0005
# Phase 1). When present and parseable, it provides build-time intent
# (which canonical container each tarball is meant to satisfy) so the
# wizard doesn't have to guess from filenames.
BUNDLE_MANIFEST_PATH="${BUNDLE_MANIFEST_PATH:-/var/lib/k0s/images/.phantomos-image-bundle.yaml}"

# Cache of the bundle's builderVersion field for the post-resolution
# summary header. Populated by _read_bundle_manifest on a successful
# parse, left empty on failure / absence / arch mismatch.
BUNDLE_BUILDER_VERSION=""

# _read_bundle_manifest
#
#   Emits stdout with a `__BUILDER_VERSION__\t<value>` line (always
#   first when output is produced) followed by one TSV line per
#   canonical-container entry: `<container>\t<ref>`.
#
#   Empty stdout means: bundle absent, unparseable, missing required
#   fields, or arch mismatch — caller falls back to section-A defaults.
#   Diagnostics (warnings, mismatch errors) go to stderr; this function
#   never fails the wizard outright.
#
#   The caller is responsible for splitting off the BUILDER_VERSION
#   sentinel from the TSV body. Done this way (rather than mutating a
#   global) because the caller will run this inside command
#   substitution, which is a subshell — globals don't propagate up.
#
#   Args:
#     $1 — bundle manifest path (default: $BUNDLE_MANIFEST_PATH)
#     $2 — host arch (Debian convention: amd64, arm64). Required for
#          arch-match check.
_read_bundle_manifest() {
  local path="${1:-$BUNDLE_MANIFEST_PATH}"
  local host_arch="${2:-}"
  [ -r "$path" ] || return 0
  python3 - "$path" "$host_arch" <<'PY'
import sys, yaml
path = sys.argv[1]
host_arch = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    with open(path) as f:
        cfg = yaml.safe_load(f)
except Exception as e:
    sys.stderr.write(f"warning: bundle manifest at {path}: {e}; ignoring\n")
    sys.exit(0)
if not isinstance(cfg, dict):
    sys.stderr.write(f"warning: bundle manifest at {path}: top-level not a mapping; ignoring\n")
    sys.exit(0)
schema = cfg.get("schemaVersion")
if schema not in (1, "1"):
    sys.stderr.write(f"warning: bundle manifest at {path}: unsupported schemaVersion={schema!r}; ignoring\n")
    sys.exit(0)
bundle_arch = cfg.get("arch")
if not bundle_arch:
    sys.stderr.write(f"warning: bundle manifest at {path}: missing 'arch'; ignoring\n")
    sys.exit(0)
if host_arch and bundle_arch != host_arch:
    sys.stderr.write(
        f"warning: bundle arch={bundle_arch} host arch={host_arch}; ignoring bundle defaults\n"
    )
    sys.exit(0)
entries = cfg.get("bundle")
if not isinstance(entries, list):
    sys.stderr.write(f"warning: bundle manifest at {path}: 'bundle' is not a list; ignoring\n")
    sys.exit(0)
# Sentinel first, so bash callers can read a single line to grab the
# builder version even if the TSV body is huge.
bv = cfg.get("builderVersion") or ""
print(f"__BUILDER_VERSION__\t{bv}")
seen = set()
for e in entries:
    if not isinstance(e, dict):
        continue
    cname = e.get("container")
    ref = e.get("ref")
    if not cname or not ref:
        continue
    if cname in seen:
        sys.stderr.write(
            f"warning: bundle manifest at {path}: duplicate container {cname!r}; using first only\n"
        )
        continue
    seen.add(cname)
    print(f"{cname}\t{ref}")
PY
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
# Bash 5.3 treats a bare `declare -a foo` as unset under `set -u`, so
# `${#foo[@]}` errors until something is assigned. Initialize empty.
declare -a seed_pos_mount_names=()
declare -a seed_pos_mount_hosts=()
declare -a seed_pos_mount_containers=()
declare -a seed_api_mount_names=()
declare -a seed_api_mount_hosts=()
declare -a seed_api_mount_containers=()
# Per-stack seed values. Empty string = "not set in seed" (use default).
seed_core_selfheal=""
seed_operator_enabled=""
seed_operator_selfheal=""
# RFC 0006 — gitSource toggle ("local" or "remote"). Empty = not in seed,
# wizard defaults to "local" on a fresh run.
seed_git_source=""

# foundation.bot/has-* node label values harvested from the prior
# host-config.yaml. Filled in below when $seed_path is set; consulted
# by the wizard's nodeLabels emit block.
declare -A seed_node_labels=()

if [ -n "$seed_path" ]; then
  seed_robot="$(python3 "$HELPER" "$seed_path" get robot 2>/dev/null || true)"
  seed_ai="$(python3 "$HELPER" "$seed_path" get aiPcUrl 2>/dev/null || true)"
  seed_target_rev="$(python3 "$HELPER" "$seed_path" get targetRevision 2>/dev/null || true)"
  seed_production="$(python3 "$HELPER" "$seed_path" get production 2>/dev/null || true)"

  # Per-stack seed values (any of these may be empty).
  # Also harvests top-level RFC 0006 `gitSource` via a synthetic
  # `top\tgitSource\t\t<value>` row. Synthetic rows use kind=top so
  # they share the same TSV stream without colliding with stack rows.
  # Note: bash read with IFS=$'\t' collapses runs of tabs, so the
  # `field` slot is intentionally a single non-empty token (`_`)
  # rather than empty — otherwise read would shift `val` into `field`.
  while IFS=$'\t' read -r kind name field val; do
    case "$kind:$name:$field" in
      stack:core:selfHeal)         seed_core_selfheal="$val" ;;
      stack:operator:enabled)      seed_operator_enabled="$val" ;;
      stack:operator:selfHeal)     seed_operator_selfheal="$val" ;;
      top:gitSource:_)             seed_git_source="$val" ;;
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
git_source = cfg.get("gitSource") if isinstance(cfg, dict) else None
if git_source:
    # `_` placeholder in the field slot — bash read collapses empty
    # tab-separated columns, so a non-empty token is required here.
    print(f"top\tgitSource\t_\t{git_source}")
PY
)
  # Pull the images: block. The schema is now container-keyed
  # (images.<container>.image: <ref:tag>); seed harvest reads the
  # YAML rather than line-grepping so we tolerate either ordering or
  # comments.
  seed_images_yaml=""
  while IFS=$'\t' read -r cname img; do
    [ -z "$cname" ] && continue
    seed_images_yaml+="${cname}"$'\t'"${img}"$'\n'
  done < <(python3 - "$seed_path" <<'PY'
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
images = cfg.get("images")
if isinstance(images, dict):
    for cname, spec in images.items():
        if isinstance(spec, dict) and spec.get("image"):
            print(f"{cname}\t{spec['image']}")
PY
)

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

  # nodeLabels harvest — pull existing foundation.bot/has-* values so
  # the wizard's always-emit block uses prior operator choices as
  # defaults. Keys absent from the prior file fall through to the
  # registry default in host-config.py:NODE_LABEL_REGISTRY.
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    seed_node_labels[$key]="$value"
  done < <(python3 - "$seed_path" <<'PY'
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
nl = cfg.get("nodeLabels") if isinstance(cfg, dict) else None
if isinstance(nl, dict):
    for k, v in nl.items():
        # Coerce bool to lowercase string so an unquoted `true` in the
        # source file round-trips as `'true'` (matches schema). Skip
        # anything else — the validator will catch malformed values.
        if isinstance(v, bool):
            print(f"{k}\t{'true' if v else 'false'}")
        elif isinstance(v, str):
            print(f"{k}\t{v}")
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

validate_git_source() {
  case "$1" in
    local|remote) return 0 ;;
    *) err "must be 'local' or 'remote' (got: $1)"; return 1 ;;
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
hint "URL of the AI PC paired with this robot. operator-ui talks to it."
hint "Two ways to set this:"
hint "  1) enter a Tailscale IP/URL manually (recommended for production)"
hint "  2) auto-detect from this robot's default-gateway interface"
hint "     (use when the AI PC sits on the same LAN as the robot's"
hint "     gateway-facing port, or when robot and AI PC are colocated)"

ai_pc_url=""
if [ "$YES" != 1 ]; then
  if confirm "Auto-detect AI PC URL from default-gateway interface?" "n"; then
    if iface_ip=$(detect_gateway_iface_ip); then
      iface=$(printf '%s' "$iface_ip" | cut -f1)
      ip=$(printf '%s'    "$iface_ip" | cut -f2)
      ok "gateway interface: $iface"
      ok "interface IP:      $ip"
      candidate="http://$ip:5000"
      if validate_url "$candidate"; then
        ai_pc_url="$candidate"
        ok "aiPcUrl = $ai_pc_url  (auto-detected)"
      else
        err "auto-detected URL failed validation: $candidate"
        err "falling back to manual entry"
      fi
    else
      err "could not detect a default gateway interface / IP on this host"
      err "falling back to manual entry"
    fi
  fi
fi

if [ -z "$ai_pc_url" ]; then
  example "http://100.124.202.97:5000"
  ai_default="$seed_ai"
  ai_pc_url="$(ask "aiPcUrl" "$ai_default" "Full URL with scheme + port. Tailscale IP recommended." validate_url)"
  ok "aiPcUrl = $ai_pc_url"
fi

# --- gitSource (RFC 0006) ---
heading "Argo source of truth"
hint "Track manifests from the local /opt/Phantom-OS-KubernetesOptions tree"
hint "(default — packaged with the .deb, atomic + offline-friendly), or"
hint "from a remote git URL like GitHub (legacy behavior, useful for fleet"
hint "ops who push hot-fixes by git push instead of rebuilding the .deb)."
hint "Legacy host-configs without a gitSource: field are treated as 'local'"
hint "on this run; type 'remote' explicitly to keep tracking GitHub."
example "local                  # default; tracks /opt/.../.git/ via file://"
example "remote                 # tracks https://github.com/... via Argo's repo-server"

# Default to local on a fresh wizard run; preserve seed value on re-run.
git_source_default="${seed_git_source:-local}"
git_source="$(ask "gitSource" "$git_source_default" "Either 'local' or 'remote'." validate_git_source)"
ok "gitSource = $git_source"

# --- targetRevision ---
# Only relevant when gitSource=remote. With local-git, bootstrap derives
# the revision from `git -C /opt/... rev-parse HEAD`, so prompting here
# would only let the operator pick a revision the local repo doesn't have.
if [ "$git_source" = "remote" ]; then
  heading "ArgoCD target revision"
  hint "Branch / tag / SHA the per-host ArgoCD Application should track."
  hint "'main' is the default for production robots; use a feature branch when"
  hint "testing changes before merge."
  example "main, feat/mk09-positronic-0.2.44-production"
  target_default="${seed_target_rev:-main}"
  target_revision="$(ask "targetRevision" "$target_default" "Any valid git ref reachable from the configured repo URL.")"
  ok "targetRevision = $target_revision"
else
  hint "(targetRevision skipped — gitSource=local; bootstrap will pin to /opt/.../.git/ HEAD)"
  target_revision=""
fi

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
heading "image overrides"
hint "Per-host image overrides. Each line names a known container and"
hint "supplies the full image ref (repo:tag) it should run on this robot."
hint "Skip this section to leave manifest defaults in effect."

inject_images=1

# Peek at the bundle manifest so the seed preview can show what the
# bundle would fill in for each canonical row. host_deb_arch isn't
# computed yet at this point in the wizard (it's resolved later when
# building canonical defaults), so derive it locally from dpkg here.
# Falls back to empty/no-op when the bundle isn't installed.
_bundle_peek_tsv=""
if command -v dpkg >/dev/null 2>&1; then
  _peek_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [ -n "$_peek_arch" ]; then
    _bundle_peek_tsv="$(_read_bundle_manifest "$BUNDLE_MANIFEST_PATH" "$_peek_arch" 2>/dev/null \
                         | grep -v '^__BUILDER_VERSION__' || true)"
  fi
fi

# bundle_ref_for <container-name> — echoes the bundle's ref (or empty).
bundle_ref_for() {
  local target="$1" line cname ref
  while IFS=$'\t' read -r cname ref; do
    [ "$cname" = "$target" ] && { printf '%s' "$ref"; return; }
  done <<< "$_bundle_peek_tsv"
}

if [ -z "$seed_images_yaml" ]; then
  # No seed — show bundle defaults if present so the operator sees
  # what's about to land before answering.
  if [ -n "$_bundle_peek_tsv" ]; then
    hint "Defaults from bundle (auto-images will use these):"
    while IFS=$'\t' read -r cname ref; do
      [ -z "$cname" ] && continue
      printf '%s    %s -> %s%s\n' "$C_DIM" "$cname" "$ref" "$C_RESET" >&2
    done <<< "$_bundle_peek_tsv"
  fi
  if ! confirm "Add image overrides? (recommended for production robots)" "y"; then
    inject_images=0
  fi
else
  # Pre-filter the seed display: any row whose tag is a wizard
  # placeholder (REPLACE-WITH-*) is rendered with what the bundle
  # would fill in. The actual img_refs[] cleanup + bundle resolution
  # happens further down (single source of truth); this is the
  # operator preview.
  hint "Defaults from seed (and what the bundle would override):"
  while IFS=$'\t' read -r cname img; do
    [ -z "$cname" ] && continue
    case "${img##*:}" in
      REPLACE-WITH-*)
        _bref="$(bundle_ref_for "$cname")"
        if [ -n "$_bref" ]; then
          printf '%s    %s -> %s (bundle override; seed placeholder cleared)%s\n' \
            "$C_DIM" "$cname" "$_bref" "$C_RESET" >&2
        else
          printf '%s    %s -> <cleared placeholder; no bundle entry, will re-prompt>%s\n' \
            "$C_DIM" "$cname" "$C_RESET" >&2
        fi
        ;;
      *)
        # Seed has a real value — it wins. Show what bundle has too if
        # different, so the operator knows there's a divergence.
        _bref="$(bundle_ref_for "$cname")"
        if [ -n "$_bref" ] && [ "$_bref" != "$img" ]; then
          printf '%s    %s -> %s  (seed wins; bundle has %s)%s\n' \
            "$C_DIM" "$cname" "$img" "$_bref" "$C_RESET" >&2
        else
          printf '%s    %s -> %s%s\n' "$C_DIM" "$cname" "$img" "$C_RESET" >&2
        fi
        ;;
    esac
  done <<< "$seed_images_yaml"
  if ! confirm "Use these as the starting point?" "y"; then
    if ! confirm "Skip image overrides entirely?" "n"; then
      die "aborted — re-run and accept defaults or pick --from-template <robot>"
    fi
    inject_images=0
  fi
fi

# Container-keyed image entries: parallel arrays (container, image-ref,
# provenance). `img_provenance[i]` records where img_refs[i] came from
# so the auto-images summary header can show the operator what landed:
#   "seed"      — preserved from /etc/phantomos/host-config.yaml
#   "bundle"    — filled from /var/lib/k0s/images/.phantomos-image-bundle.yaml
#   "section-A" — filled from operator-ui filename scan / arch derivation
#   ""          — empty / no override (manifest default applies)
# Emitted as `images: { <container>: { image: <ref> } }` at the end.
img_containers=()
img_refs=()
img_provenance=()

if [ "$inject_images" = 1 ]; then
  # dma-ethercat is the one container whose default tag depends on
  # the host CPU architecture (CI publishes -aarch64 for arm64/Jetson
  # robots, -amd64 for x86 robots). Detect the running arch once and
  # use it for both:
  #   1. seed sanity-check below (rewrite an obviously-wrong-arch
  #      seeded tag so the operator doesn't have to remember the
  #      convention when migrating a config across machines);
  #   2. canonical_default_tags below (right default on a fresh wizard
  #      run with no seed).
  # Plain assignment (not `local`) — this block is at script scope.
  # `uname -m` returns the kernel arch (`x86_64`, `aarch64`); the
  # Debian / docker-tag convention is `amd64` / `arm64`. They mean
  # the same hardware — normalize to the Debian convention so all
  # downstream comparisons and user-facing messages use one vocabulary.
  host_kernel_arch="$(uname -m)"
  host_deb_arch=""
  dma_ethercat_default_tag=""
  # `dma_ethercat_wrong_tags` is a space-separated list of TAG strings
  # the auto-correct should rewrite to dma_ethercat_default_tag. It
  # covers two cases:
  #   1. Wrong-arch tag (e.g. -aarch64 ref on an amd64 host).
  #   2. Outdated-same-arch tag (e.g. -amd64 ref on an amd64 host
  #      where CI now publishes as bare `main-latest`).
  dma_ethercat_wrong_tags=""
  case "$host_kernel_arch" in
    aarch64|arm64)
      host_deb_arch="arm64"
      # CI publishes the arm64 build as `main-latest-aarch64`.
      # Wrong: -amd64 suffix (other arch), or bare `main-latest`
      # (amd64 convention used by mistake).
      dma_ethercat_default_tag="main-latest-aarch64"
      dma_ethercat_wrong_tags="main-latest-amd64 main-latest" ;;
    x86_64|amd64)
      host_deb_arch="amd64"
      # CI publishes the amd64 build as bare `main-latest`. Wrong:
      # -aarch64 suffix (other arch), or -amd64 suffix (obsolete CI
      # naming used before the bare-tag move).
      dma_ethercat_default_tag="main-latest"
      dma_ethercat_wrong_tags="main-latest-aarch64 main-latest-amd64" ;;
    *)
      host_deb_arch="$host_kernel_arch"
      dma_ethercat_default_tag="main-latest-${host_kernel_arch}"
      dma_ethercat_wrong_tags="" ;;
  esac

  # Parse seed entries (one TSV line per container) into arrays.
  if [ -n "$seed_images_yaml" ]; then
    while IFS=$'\t' read -r cname img; do
      [ -z "$cname" ] && continue
      # Auto-correct a seeded dma-ethercat tag that targets a different
      # arch than this host (typical when an existing host-config is
      # copied across architectures). Operator can still override at
      # the prompt; we just stop offering them the wrong default.
      if [ "$cname" = "dma-ethercat" ] && [ -n "$dma_ethercat_wrong_tags" ]; then
        # Pull the tag part of the seed (everything after the last `:`)
        # and check it against the list of known-wrong tags for this
        # host's arch. Covers both wrong-arch suffixes and outdated
        # same-arch tags (the latter happens when CI changed naming
        # convention but operator host-configs still carry the old tag).
        seeded_tag="${img##*:}"
        needs_fix=0
        for wrong_tag in $dma_ethercat_wrong_tags; do
          [ "$seeded_tag" = "$wrong_tag" ] && needs_fix=1 && break
        done
        if [ "$needs_fix" = 1 ]; then
          fixed="foundationbot/dma-ethercat:${dma_ethercat_default_tag}"
          printf '%s  warning%s seeded dma-ethercat ref %s\n' "$C_DIM" "$C_RESET" "$img" >&2
          printf '%s           is wrong/outdated for this host (%s)\n' "$C_DIM" "$host_deb_arch" >&2
          printf '%s           rewriting to %s%s\n' "$C_DIM" "$fixed" "$C_RESET" >&2
          img="$fixed"
        fi
      fi
      img_containers+=("$cname")
      img_refs+=("$img")
      img_provenance+=("seed")
    done <<< "$seed_images_yaml"
  fi

  # Auto-clear seed entries that carry a REPLACE-WITH-* placeholder
  # tag. These were previously written by configure-host.sh itself (a
  # bug — see docs/image-flow-and-registry-bootstrap.md), but they
  # would never resolve at pull time. Treat them as if the seed had
  # no entry, so the bundle / section-A defaults can fill the gap.
  #
  # MUST run before bundle resolution: clearing turns the seed entry
  # back into an empty row, letting the bundle-fill step below give
  # it a real ref. This was previously after the canonical_default
  # loop; moved up so the bundle reader sees the correct empty state.
  for i in "${!img_refs[@]}"; do
    case "${img_refs[$i]##*:}" in
      REPLACE-WITH-*)
        printf '%s  warning%s seed %s ref %s carries placeholder tag,\n' \
          "$C_DIM" "$C_RESET" "${img_containers[$i]}" "${img_refs[$i]}" >&2
        printf '%s           clearing — re-prompt with canonical default%s\n' \
          "$C_DIM" "$C_RESET" >&2
        img_refs[$i]=""
        img_provenance[$i]=""
        ;;
    esac
  done

  # ---- Phase 3: bundle-manifest reader -----------------------------
  #
  # Read /var/lib/k0s/images/.phantomos-image-bundle.yaml (when present
  # and arch-matched) and use bundle[].ref as the default for any
  # canonical container that doesn't already have a non-empty seed
  # entry. Seed wins absolutely; bundle fills gaps.
  #
  # _read_bundle_manifest emits TSV `<container>\t<ref>` lines. Empty
  # output means no bundle / unparseable / arch mismatch — we just
  # don't fill any rows here and the section-A defaults below take
  # over (preserving the older code path verbatim).
  bundle_seen_count=0
  # Capture stdout from the function into a string (not process
  # substitution) so the BUILDER_VERSION sentinel parse below stays
  # in the same shell. The function emits the sentinel as the first
  # line, followed by TSV `<container>\t<ref>` rows.
  _bundle_tsv="$(_read_bundle_manifest "$BUNDLE_MANIFEST_PATH" "$host_deb_arch")"
  if [ -n "$_bundle_tsv" ]; then
    while IFS=$'\t' read -r bcname bref; do
      [ -z "$bcname" ] && continue
      if [ "$bcname" = "__BUILDER_VERSION__" ]; then
        BUNDLE_BUILDER_VERSION="$bref"
        continue
      fi
      [ -z "$bref" ] && continue
      bundle_seen_count=$((bundle_seen_count + 1))
      # Find existing row, or append.
      found_idx=-1
      for i in "${!img_containers[@]}"; do
        if [ "${img_containers[$i]}" = "$bcname" ]; then
          found_idx=$i; break
        fi
      done
      if [ "$found_idx" -ge 0 ]; then
        # Seed entry exists. Preserve it absolutely — only fill when
        # the slot is currently empty (REPLACE-WITH-* clear path or
        # operator hand-cleared the line on a previous run).
        if [ -z "${img_refs[$found_idx]}" ]; then
          img_refs[$found_idx]="$bref"
          img_provenance[$found_idx]="bundle"
        fi
      else
        img_containers+=("$bcname")
        img_refs+=("$bref")
        img_provenance+=("bundle")
      fi
    done <<< "$_bundle_tsv"
  fi

  # operator-ui default tag — derived from the bundled image .deb if
  # installed, so press-enter accepts a tag the worker can actually
  # serve from containerd's local store. The .deb's tarball naming
  # convention is `<repo-with-slashes-as-dashes>_<tag>.tar`, so
  # e.g. /var/lib/k0s/images/foundationbot-argus.operator-ui_qa.tar
  # implies tag `qa`. Falls back to empty when the .deb isn't
  # installed — the prompt's "Empty to skip" path then kicks in and
  # the manifest's in-tree default applies (currently `:qa`).
  operator_ui_default_tag=""
  for f in /var/lib/k0s/images/foundationbot-argus.operator-ui_*.tar; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    base="${base%.tar}"
    operator_ui_default_tag="${base##*_}"
    break
  done

  # Canonical fleet container set + default repo (without tag). Each
  # entry in CONTAINER_TARGETS gets a row here so adding a workload
  # is a single-line change. Tag defaults are held in
  # canonical_default_tags; the operator can override the whole
  # ref (repo + tag) at the prompt.
  #
  # Empty default tag = the prompt is offered with no preloaded value,
  # press-Enter skips the override entirely, and the base manifest's
  # in-tree image:tag wins. This is the right default for containers
  # the operator must build locally (positronic-control,
  # phantom-models): an unfilled placeholder used to be silently
  # injected into Argo as a non-resolving tag. See
  # docs/image-flow-and-registry-bootstrap.md for the post-mortem.
  declare -a canonical_containers=(
    "positronic-control"
    "phantom-models"
    "operator-ui"
    "dma-ethercat"
  )
  declare -a canonical_default_repos=(
    "localhost:5443/positronic-control"
    "localhost:5443/phantom-models"
    "foundationbot/argus.operator-ui"
    "foundationbot/dma-ethercat"
  )
  declare -a canonical_default_tags=(
    ""                              # positronic-control: must be local build
    ""                              # phantom-models:     must be local build
    "$operator_ui_default_tag"      # operator-ui:        from .deb if installed
    "$dma_ethercat_default_tag"     # dma-ethercat:       arch-derived
  )

  # Append any canonical container missing from the seed/bundle.
  # Existing entries are preserved as-is; missing ones get the
  # canonical (section-A) default so the operator can press enter to
  # accept. When the canonical default tag is empty (no real value to
  # suggest) the row is added with an empty ref — press-Enter then
  # drops the override and the manifest default applies.
  #
  # Seed and bundle wins are already in place from earlier steps;
  # this loop only fills rows that are truly empty after both higher-
  # priority sources had a chance.
  for c_i in "${!canonical_containers[@]}"; do
    c_name="${canonical_containers[$c_i]}"
    found_idx=-1
    for i in "${!img_containers[@]}"; do
      if [ "${img_containers[$i]}" = "$c_name" ]; then
        found_idx=$i; break
      fi
    done
    if [ "$found_idx" = -1 ]; then
      img_containers+=("$c_name")
      if [ -n "${canonical_default_tags[$c_i]}" ]; then
        img_refs+=("${canonical_default_repos[$c_i]}:${canonical_default_tags[$c_i]}")
        img_provenance+=("section-A")
      else
        img_refs+=("")
        img_provenance+=("")
      fi
    elif [ -z "${img_refs[$found_idx]}" ]; then
      # Row exists but is empty (REPLACE-WITH-* clear, or hand-cleared
      # seed). Bundle didn't fill it. Last-resort section-A fill.
      if [ -n "${canonical_default_tags[$c_i]}" ]; then
        img_refs[$found_idx]="${canonical_default_repos[$c_i]}:${canonical_default_tags[$c_i]}"
        img_provenance[$found_idx]="section-A"
      fi
      # else: still empty, provenance stays "" — that's fine, means
      # "no override, manifest default applies".
    fi
  done

  # ---- Phase 4: --auto-images resolution ----------------------------
  #
  # Decide whether to skip the per-row prompts. Default ON when the
  # bundle manifest yielded any usable entries (bundle_seen_count>0);
  # default OFF otherwise. CLI flags / env var override.
  effective_auto_images="$AUTO_IMAGES"
  if [ "$effective_auto_images" = -1 ]; then
    if [ "$bundle_seen_count" -gt 0 ]; then
      effective_auto_images=1
    else
      effective_auto_images=0
    fi
  fi

  # If --auto-images is on but resolution leaves ALL canonical rows
  # empty (no seed, no bundle, no section-A fill), refuse to ship a
  # host-config with no images: block. Drop into the prompt loop as a
  # safety net — better to ask than to ship a guaranteed
  # ImagePullBackOff.
  if [ "$effective_auto_images" = 1 ]; then
    nonempty_resolution=0
    for i in "${!img_refs[@]}"; do
      [ -n "${img_refs[$i]}" ] && nonempty_resolution=$((nonempty_resolution + 1))
    done
    if [ "$nonempty_resolution" = 0 ]; then
      printf '%s  warning%s --auto-images: all canonical rows resolved empty;\n' \
        "$C_DIM" "$C_RESET" >&2
      printf '%s           dropping into the prompt loop instead%s\n' \
        "$C_DIM" "$C_RESET" >&2
      effective_auto_images=0
    fi
  fi

  if [ "$effective_auto_images" = 1 ]; then
    # Print a one-line summary header showing where each row's ref
    # came from, then skip the prompts entirely. Operators who want
    # to inspect or override what landed re-run with
    # `--no-auto-images`.
    declare -A _prov_count=([seed]=0 [bundle]=0 [section-A]=0 [empty]=0)
    for i in "${!img_provenance[@]}"; do
      p="${img_provenance[$i]}"
      [ -z "$p" ] && p="empty"
      _prov_count[$p]=$((${_prov_count[$p]:-0} + 1))
    done
    total_rows=${#img_containers[@]}
    summary_parts=()
    [ "${_prov_count[bundle]:-0}" -gt 0 ] && summary_parts+=("${_prov_count[bundle]} from bundle${BUNDLE_BUILDER_VERSION:+ $BUNDLE_BUILDER_VERSION}")
    [ "${_prov_count[seed]:-0}" -gt 0 ] && summary_parts+=("${_prov_count[seed]} from seed")
    [ "${_prov_count[section-A]:-0}" -gt 0 ] && summary_parts+=("${_prov_count[section-A]} from section-A")
    [ "${_prov_count[empty]:-0}" -gt 0 ] && summary_parts+=("${_prov_count[empty]} empty")
    summary_str=""
    for s in "${summary_parts[@]}"; do
      if [ -z "$summary_str" ]; then summary_str="$s"
      else summary_str="$summary_str, $s"
      fi
    done
    echo
    info "auto-images: $total_rows rows ($summary_str)"
    info "(use --no-auto-images to interactively review/override these refs)"
    for i in "${!img_containers[@]}"; do
      prov="${img_provenance[$i]:-empty}"
      ref_display="${img_refs[$i]}"
      [ -z "$ref_display" ] && ref_display="<no override; manifest default applies>"
      printf '%s    %-22s %-12s %s%s\n' \
        "$C_DIM" "${img_containers[$i]}" "[$prov]" "$ref_display" "$C_RESET" >&2
    done
  else
    echo
    if [ "$bundle_seen_count" -gt 0 ]; then
      hint "Bundle manifest contributed ${bundle_seen_count} ref(s); each prompt is"
      hint "pre-filled with the resolved seed -> bundle -> section-A default."
    fi
    hint "Press enter to keep the shown default; an empty default means"
    hint "no override (the manifest's in-tree image:tag will apply)."
    hint "Swapping repos is fine — bootstrap renames+retags in one step."
    example "localhost:5443/positronic-control:0.2.44-production-cu130"
    example "foundationbot/phantom-cuda:0.2.46-dev.1-production-cu130 (swap repo)"
    example "localhost:5443/phantom-models:2026-04-30                  (date-stamped)"
    example "foundationbot/argus.operator-ui:<git-sha>"
    example "foundationbot/dma-ethercat:main-latest-aarch64            (arm64)"
    example "foundationbot/dma-ethercat:main-latest-amd64              (x86)"
    for i in "${!img_containers[@]}"; do
      new_ref="$(ask "${img_containers[$i]} image" "${img_refs[$i]}" "Full image ref (repo:tag). Empty to skip this container.")"
      img_refs[$i]="$new_ref"
    done
  fi
fi

# --- deployments: positronic-control mounts ---------------------------
heading "deployments: positronic-control mounts"
hint "Per-host hostPath mounts injected into the positronic-control pod."
hint "The base manifest carries only kernel mounts (/dev, /dev/shm, /tmp);"
hint "everything else — source checkout, data partitions, recordings,"
hint "torch cache, training data — comes from this list."

# Final state:
declare -a pos_mount_names=()
declare -a pos_mount_hosts=()
declare -a pos_mount_containers=()
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
declare -a kept_names=() kept_hosts=() kept_containers=()
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

declare -a api_mount_names=()
declare -a api_mount_hosts=()
declare -a api_mount_containers=()

api_default="n"
[ "${#seed_api_mount_names[@]}" -gt 0 ] && api_default="y"
if confirm "Configure phantomos-api-server mounts?" "$api_default"; then
  if [ "${#seed_api_mount_names[@]}" -gt 0 ]; then
    api_mount_names=("${seed_api_mount_names[@]}")
    api_mount_hosts=("${seed_api_mount_hosts[@]}")
    api_mount_containers=("${seed_api_mount_containers[@]}")
    hint "Editing ${#api_mount_names[@]} mounts from seed."
  fi
  declare -a api_kept_names=() api_kept_hosts=() api_kept_containers=()
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
  printf 'gitSource: %s\n' "$git_source"
  if [ "$git_source" = "remote" ] && [ -n "$target_revision" ]; then
    printf 'targetRevision: %s\n' "$target_revision"
  fi
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
    # Count non-empty refs so we don't emit an empty `images:` header.
    nonempty=0
    for i in "${!img_containers[@]}"; do
      [ -n "${img_refs[$i]}" ] && nonempty=$((nonempty + 1))
    done
    if [ "$nonempty" -gt 0 ]; then
      printf 'images:\n'
      for i in "${!img_containers[@]}"; do
        [ -z "${img_refs[$i]}" ] && continue
        printf '  %s:\n' "${img_containers[$i]}"
        printf '    image: %s\n' "${img_refs[$i]}"
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

  # nodeLabels: always emitted, with every gate from the registry
  # explicit so a developer reading host-config.yaml can see at a
  # glance which workloads are (de)scheduled on this robot. Per-key
  # values come from the prior host-config when present, else from
  # the registry default. Source of truth for keys + defaults +
  # descriptions: scripts/lib/host-config.py:NODE_LABEL_REGISTRY.
  printf 'nodeLabels:\n'
  printf '  # Gates per-robot workloads via Kubernetes nodeSelectors. Bootstrap\n'
  printf '  # reconciles the node'"'"'s foundation.bot/* labels from this block on\n'
  printf '  # every run. Edit a value to (de)schedule the workload on this host.\n'
  while IFS=$'\t' read -r nl_key nl_default nl_desc; do
    [ -n "$nl_key" ] || continue
    nl_value="$nl_default"
    if [ "${seed_node_labels[$nl_key]+x}" = "x" ]; then
      nl_value="${seed_node_labels[$nl_key]}"
    fi
    printf '  # %s\n' "$nl_desc"
    printf "  %s: '%s'\n" "$nl_key" "$nl_value"
  done < <(python3 "$HELPER" /dev/null get-node-label-defaults)
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
