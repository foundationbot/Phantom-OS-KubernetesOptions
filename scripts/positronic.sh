#!/usr/bin/env bash
# positronic.sh — convenience wrapper for the positronic-control deployment.
#
# Single entry point for the day-to-day lifecycle operations against the
# positronic-control Deployment in the `positronic` namespace. Designed to
# be friendly on the robot (where only `k0s kubectl` is available) and on
# laptops (where `kubectl` is the usual tool). Read-only commands degrade
# gracefully when neither is available.
#
# Usage:
#   bash scripts/positronic.sh <subcommand> [args...]
#   bash scripts/positronic.sh help
#
# See `help` subcommand for the full list. Companion to:
#   scripts/diagnose-positronic.sh    — deep diagnostic + apply overlay
#   scripts/configure-k0s-*.sh        — host-level bootstrap

set -u -o pipefail

# ---------- defaults (env overridable) -------------------------------------

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"

# Robot identity — set via --robot <name>, or auto-detected from hostname.
# Validated after arg parsing (see _resolve_robot below).
ROBOT="${ROBOT:-}"

NAMESPACE="${NAMESPACE:-positronic}"
APP_LABEL="${APP_LABEL:-app=positronic-control}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-positronic-config}"
CONTAINER_NAME="${CONTAINER_NAME:-positronic-control}"
INIT_CONTAINER_NAME="${INIT_CONTAINER_NAME:-load-models}"
IMAGE_NAME="${IMAGE_NAME:-localhost:5443/positronic-control}"

TRACK_ROOT_APP="${TRACK_ROOT_APP:-root}"
TRACK_ROOT_NS="${TRACK_ROOT_NS:-argocd}"
ARGO_NS="${ARGO_NS:-argocd}"

DRY_RUN=0

# Pull in the shared robot-identity helper. resolve_robot honors (in
# order): explicit --robot/ROBOT, /etc/phantomos/robot, hostname.
REPO_ROOT="$REPO"
# shellcheck source=lib/robot-id.sh
. "$(dirname "$0")/lib/robot-id.sh"

# _resolve_robot — called after arg parsing to finalise ROBOT and derived vars.
_resolve_robot() {
  local resolved
  if ! resolved="$(resolve_robot "$ROBOT")"; then
    # resolve_robot prints its own diagnostic. Fall back to interactive
    # prompt for backwards compatibility on dev laptops.
    printf 'Enter robot name: ' >&2
    read -r ROBOT
    [ -n "$ROBOT" ] || die "robot name is required"
    if ! resolved="$(resolve_robot "$ROBOT")"; then
      die "robot name $ROBOT did not resolve"
    fi
  fi
  ROBOT="$resolved"

  # Derived paths (still env-overridable).
  # positronic-control lives in the `core` stack post-restructure.
  OVERLAY="${OVERLAY:-${REPO}/manifests/stacks/core}"
  TRACK_APP_FILE="${TRACK_APP_FILE:-${REPO}/gitops/apps/${ROBOT}/phantomos-${ROBOT}.yaml}"
  ARGO_APP="${ARGO_APP:-phantomos-${ROBOT}}"
}

# ---------- color helpers (only when stdout is a TTY) ---------------------

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

bold() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$C_RED"    "$C_RESET" "$1"; }
info() { printf '  %s%s\n' "$C_BLUE" "$1$C_RESET"; }

die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit "${2:-1}"; }

# ---------- kubectl resolution --------------------------------------------
# Returns 0 if a kubectl backend was found, 1 if not. Sets KUBECTL.

KUBECTL=""

resolve_kubectl() {
  if [ -n "$KUBECTL" ]; then return 0; fi
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL="kubectl"
    return 0
  fi
  if command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
    KUBECTL="k0s kubectl"
    return 0
  fi
  return 1
}

require_kubectl() {
  if resolve_kubectl; then return 0; fi
  # In dry-run we want to print the would-be command even on machines
  # without a kubectl backend (e.g. reviewing the script on a laptop).
  if [ "$DRY_RUN" = 1 ]; then
    KUBECTL="kubectl"
    warn "no kubectl backend found — dry-run will use 'kubectl' as a placeholder"
    return 0
  fi
  die "neither kubectl nor 'k0s kubectl' is available on this host" 2
}

# Run a kubectl command honoring DRY_RUN. When DRY_RUN=1 we just print the
# command with one-line shell quoting and return 0. Otherwise we exec it.
# Note: this is for fire-and-forget commands; use `kctl_capture` when you
# need stdout, and call `$KUBECTL ...` directly for streaming subcommands
# (logs -f, exec -it, get -w) where DRY_RUN is handled at the caller.
kctl() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s' "$KUBECTL"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    return 0
  fi
  $KUBECTL "$@"
}

# Capture-only variant — used for the existence/state checks that drive
# the rest of a subcommand. Honors DRY_RUN by returning empty string.
kctl_capture() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s' "$KUBECTL"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n' >&2
    return 0
  fi
  $KUBECTL "$@"
}

# ---------- pod lookup -----------------------------------------------------

# Echos the running pod name, or empty if no pod matches.
# In dry-run mode (or when kubectl isn't usable) it returns a placeholder
# token so downstream subcommands can print a coherent kubectl line.
get_pod() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '<pod>'
    return 0
  fi
  $KUBECTL -n "$NAMESPACE" get pod -l "$APP_LABEL" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# ---------- subcommand: help ----------------------------------------------

cmd_help() {
  cat <<EOF
${C_BOLD}positronic.sh${C_RESET} — wrapper for the positronic-control deployment

${C_BOLD}Usage:${C_RESET}
  bash scripts/positronic.sh [--robot <name>] [--dry-run] <subcommand> [args...]

${C_BOLD}Subcommands:${C_RESET}
  status                       Pod state, QoS, restarts, runtimeClassName,
                               PHANTOM_CMD (CM + as-seen-by-pod), PID 1 cmd.
  logs [-f|--follow] [--previous] [--init]
                               Stream logs from the main container (or the
                               load-models init container with --init).
                               --previous reads the prior crashed instance.
  exec [-- command...]         Drop into bash (--norc --noprofile) by
                               default, or run an arbitrary command if
                               args follow '--'.
  gpu-test                     Run a PyTorch CUDA matmul inside the pod;
                               PASS iff cuda is available and result != 0.
  set-cmd <command...>         Set PHANTOM_CMD in $CONFIGMAP_NAME to the
                               joined args, then rollout restart the
                               Deployment so the new command takes effect.
  clear-cmd                    Set PHANTOM_CMD to empty (interactive dev
                               mode → sleep infinity), rollout restart.
  push-image <src> [--tag <dest-tag>] [--no-redeploy]
                               Tag local docker image <src> as
                               $IMAGE_NAME:<dest-tag>, push it, and bump
                               newTag in the overlay's kustomization.yaml
                               so the cluster picks it up. Then redeploys
                               (skip with --no-redeploy). <dest-tag>
                               defaults to <src>'s own tag.
  redeploy                     kubectl apply -k <overlay>, then bounce the
                               pod. Same as APPLY=1 diagnose-positronic.sh
                               minus the diagnose phase.
  track-branch [<branch>]      Point ArgoCD's root app at <branch> (default:
                               current git branch). Edits + commits + pushes
                               targetRevision in the robot's app manifest,
                               then patches the live root Application. ArgoCD
                               reconciles within ~3 min. Flip back:
                               track-branch main.
  argo-pause                   Disable selfHeal on the robot's ArgoCD app so
                               a manual 'kubectl apply -k' against the overlay
                               sticks. Auto-sync stays on (git changes still
                               apply); cluster drift just isn't reverted.
                               Resume with argo-resume.
  argo-resume                  Re-enable selfHeal on the robot's ArgoCD app.
  teardown [-y|--yes]          Delete the Deployment + ConfigMap + ns.
                               Cluster-side only — does not touch manifests.
  help                         This message.

${C_BOLD}Global flags:${C_RESET}
  --robot <name>               Robot identifier (matches a directory under
                               metadata.name suffix. Auto-detected from
                               hostname when omitted; prompts if ambiguous.
  --dry-run                    Print kubectl commands instead of running
                               them. Useful for review.

${C_BOLD}Env overrides:${C_RESET}
  ROBOT            (default: auto-detected from hostname)
  NAMESPACE        (default: $NAMESPACE)
  APP_LABEL        (default: $APP_LABEL)
  OVERLAY          (default: \$REPO/manifests/stacks/core)
  CONFIGMAP_NAME   (default: $CONFIGMAP_NAME)
  IMAGE_NAME       (default: $IMAGE_NAME)
  TRACK_APP_FILE   (default: \$REPO/gitops/apps/\$ROBOT/phantomos-\$ROBOT.yaml)
  TRACK_ROOT_APP   (default: $TRACK_ROOT_APP)
  TRACK_ROOT_NS    (default: $TRACK_ROOT_NS)
  ARGO_APP         (default: phantomos-\$ROBOT)
  ARGO_NS          (default: $ARGO_NS)

${C_BOLD}Examples:${C_RESET}
  bash scripts/positronic.sh status
  bash scripts/positronic.sh logs -f
  bash scripts/positronic.sh logs --previous --init
  bash scripts/positronic.sh exec
  bash scripts/positronic.sh exec -- ros2 topic list
  bash scripts/positronic.sh gpu-test
  bash scripts/positronic.sh set-cmd ros2 launch srg_localization global_positioning_launch.py
  bash scripts/positronic.sh clear-cmd
  bash scripts/positronic.sh push-image positronic-control:0.2.45-cu130
  bash scripts/positronic.sh push-image phantom-cuda:dev --tag 0.2.45-dev
  bash scripts/positronic.sh push-image positronic-control:0.2.45 --no-redeploy
  bash scripts/positronic.sh redeploy
  bash scripts/positronic.sh track-branch                   # current git branch
  bash scripts/positronic.sh track-branch feat/my-fix
  bash scripts/positronic.sh track-branch main              # flip back
  bash scripts/positronic.sh argo-pause
  bash scripts/positronic.sh argo-resume
  bash scripts/positronic.sh teardown -y
  bash scripts/positronic.sh --dry-run set-cmd 'sleep 10'
EOF
}

# ---------- subcommand: status --------------------------------------------

cmd_status() {
  require_kubectl

  bold "Deployment ($NAMESPACE/positronic-control)"
  if ! $KUBECTL -n "$NAMESPACE" get deploy positronic-control >/dev/null 2>&1; then
    fail "Deployment positronic-control not found in $NAMESPACE — not deployed"
    return 0
  fi
  $KUBECTL -n "$NAMESPACE" get deploy positronic-control \
    -o wide 2>/dev/null | sed 's/^/    /'

  bold "Pod"
  local pod
  pod="$(get_pod)"
  if [ -z "$pod" ]; then
    warn "no pod found for label $APP_LABEL"
    return 0
  fi

  $KUBECTL -n "$NAMESPACE" get pod "$pod" -o wide 2>/dev/null | sed 's/^/    /'

  bold "Pod details"
  local jp='{range .status.containerStatuses[?(@.name=="'"$CONTAINER_NAME"'")]}restartCount={.restartCount}{"\n"}ready={.ready}{"\n"}{end}qosClass={.status.qosClass}{"\n"}runtimeClassName={.spec.runtimeClassName}{"\n"}phase={.status.phase}{"\n"}'
  $KUBECTL -n "$NAMESPACE" get pod "$pod" -o jsonpath="$jp" 2>/dev/null \
    | awk 'NF' | sed 's/^/    /'
  printf '\n'

  bold "ConfigMap PHANTOM_CMD ($CONFIGMAP_NAME)"
  local cm_cmd
  cm_cmd="$($KUBECTL -n "$NAMESPACE" get cm "$CONFIGMAP_NAME" \
            -o jsonpath='{.data.PHANTOM_CMD}' 2>/dev/null || true)"
  if [ -z "$cm_cmd" ]; then
    info "(empty — pod runs sleep infinity)"
  else
    printf '    %s\n' "$cm_cmd"
  fi

  bold "PHANTOM_CMD as seen by the pod"
  local pod_cmd
  pod_cmd="$($KUBECTL -n "$NAMESPACE" exec "$pod" -c "$CONTAINER_NAME" -- \
             sh -c 'printf %s "${PHANTOM_CMD-}"' 2>/dev/null || true)"
  if [ -z "$pod_cmd" ]; then
    info "(empty)"
  else
    printf '    %s\n' "$pod_cmd"
  fi

  bold "PID 1 command (what's actually running)"
  # /proc/1/cmdline is NUL-separated. tr to spaces for readability.
  local pid1
  pid1="$($KUBECTL -n "$NAMESPACE" exec "$pod" -c "$CONTAINER_NAME" -- \
          sh -c 'tr "\0" " " < /proc/1/cmdline; echo' 2>/dev/null || true)"
  if [ -z "$pid1" ]; then
    warn "could not read /proc/1/cmdline (pod may not be Ready)"
  else
    printf '    %s\n' "$pid1"
  fi

  # Live hostPath mounts — what the running pod actually has bind-mounted.
  # Joined by volume name so the output is host -> container.
  bold "hostPath mounts (live pod spec)"
  if ! command -v python3 >/dev/null 2>&1; then
    info "(python3 unavailable — cannot pretty-print mounts)"
  else
    local mounts_out
    mounts_out="$($KUBECTL -n "$NAMESPACE" get pod "$pod" -o json 2>/dev/null \
      | python3 -c '
import json, sys
p = json.load(sys.stdin)
volumes = {v["name"]: v["hostPath"]["path"]
           for v in p.get("spec", {}).get("volumes", [])
           if v.get("hostPath")}
container = next((c for c in p["spec"].get("containers", [])
                  if c.get("name") == "'"$CONTAINER_NAME"'"), None)
if not container:
    sys.exit(0)
mounts = [(volumes[m["name"]], m["mountPath"], m.get("readOnly", False))
          for m in container.get("volumeMounts", []) if m["name"] in volumes]
if not mounts:
    print("(none)")
else:
    width = max(len(h) for h, _, _ in mounts)
    for host, ctr, ro in mounts:
        ro_tag = "  (ro)" if ro else ""
        print(f"{host:<{width}}  ->  {ctr}{ro_tag}")
' 2>/dev/null || true)"
    if [ -z "$mounts_out" ]; then
      info "(could not parse pod spec)"
    else
      printf '%s\n' "$mounts_out" | sed 's/^/    /'
    fi
  fi

  # devMode intent from /etc/phantomos/host-config.yaml. Tells the operator
  # what the host expects, independent of what's currently running. A
  # disagreement between the two means bootstrap hasn't been re-run since
  # the host-config changed.
  bold "devMode (intent, /etc/phantomos/host-config.yaml)"
  local hc=/etc/phantomos/host-config.yaml
  if [ ! -r "$hc" ]; then
    info "(no host-config.yaml — devMode not configured)"
  elif ! command -v python3 >/dev/null 2>&1; then
    info "(python3 unavailable)"
  else
    local dev_out
    dev_out="$(python3 - "$hc" <<'PY' 2>/dev/null
import sys, json
try:
    import yaml
except ImportError:
    print("(PyYAML missing — install python3-yaml)")
    sys.exit(0)
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
except Exception as exc:
    print(f"(error reading host-config: {exc})")
    sys.exit(0)
dev = (cfg.get("devMode") or {}).get("positronic-control")
if not dev:
    print("(devMode not set — production topology)")
    sys.exit(0)
print(f"source:     {dev.get('source', '<unset>')}")
print(f"privileged: {dev.get('privileged', False)}")
mnts = dev.get("mounts") or []
print(f"mounts:     {len(mnts)} configured")
for i, m in enumerate(mnts):
    if isinstance(m, dict) and m.get("host") and m.get("container"):
        print(f"  [{i}] {m['host']}  ->  {m['container']}")
PY
)"
    printf '%s\n' "$dev_out" | sed 's/^/    /'
  fi
}

# ---------- subcommand: logs ----------------------------------------------

cmd_logs() {
  require_kubectl

  local follow=0 previous=0 init=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow)   follow=1; shift ;;
      --previous|-p) previous=1; shift ;;
      --init)        init=1; shift ;;
      -h|--help)     echo "logs [-f|--follow] [--previous] [--init]"; return 0 ;;
      *) die "unknown logs flag: $1" ;;
    esac
  done

  local pod
  pod="$(get_pod)"
  if [ -z "$pod" ]; then
    die "no pod found for label $APP_LABEL"
  fi

  local container="$CONTAINER_NAME"
  if [ "$init" = 1 ]; then container="$INIT_CONTAINER_NAME"; fi

  local args=(-n "$NAMESPACE" logs "$pod" -c "$container")
  [ "$follow" = 1 ]   && args+=(-f)
  [ "$previous" = 1 ] && args+=(--previous)

  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s' "$KUBECTL"
    for a in "${args[@]}"; do printf ' %q' "$a"; done
    printf '\n'
    return 0
  fi
  exec $KUBECTL "${args[@]}"
}

# ---------- subcommand: exec ----------------------------------------------

cmd_exec() {
  require_kubectl

  # Args after `--` are the command to run. No `--` (or nothing after) -> bash.
  local found_dd=0
  local rest=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ] && [ "$found_dd" = 0 ]; then
      found_dd=1; shift; continue
    fi
    if [ "$found_dd" = 1 ]; then
      rest+=("$1")
    else
      case "$1" in
        -h|--help) echo "exec [-- command...]"; return 0 ;;
        *) die "unknown exec flag: $1 (did you forget '--' before the command?)" ;;
      esac
    fi
    shift
  done

  local pod
  pod="$(get_pod)"
  if [ -z "$pod" ]; then
    die "no pod found for label $APP_LABEL"
  fi

  if [ "${#rest[@]}" -eq 0 ]; then
    rest=(bash --norc --noprofile)
  fi

  local args=(-n "$NAMESPACE" exec -it "$pod" -c "$CONTAINER_NAME" -- "${rest[@]}")

  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s' "$KUBECTL"
    for a in "${args[@]}"; do printf ' %q' "$a"; done
    printf '\n'
    return 0
  fi
  exec $KUBECTL "${args[@]}"
}

# ---------- subcommand: gpu-test ------------------------------------------

cmd_gpu_test() {
  require_kubectl

  local pod
  pod="$(get_pod)"
  if [ -z "$pod" ]; then
    die "no pod found for label $APP_LABEL"
  fi

  bold "GPU test (PyTorch CUDA matmul) on pod $pod"

  # The canonical one-liner. Print "cuda available: True/False" then a
  # matmul sum so we can grep both signals out of the output.
  local py='
import torch, sys
avail = torch.cuda.is_available()
print(f"cuda available: {avail}")
if not avail:
    sys.exit(0)
print(f"device: {torch.cuda.get_device_name(0)}")
a = torch.randn(1024, 1024, device="cuda")
b = torch.randn(1024, 1024, device="cuda")
c = a @ b
s = float(c.sum().item())
print(f"matmul sum: {s}")
'

  local out
  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s -n %q exec %q -c %q -- python3 -c <pytorch matmul script>\n' \
      "$KUBECTL" "$NAMESPACE" "$pod" "$CONTAINER_NAME"
    return 0
  fi

  if ! out="$($KUBECTL -n "$NAMESPACE" exec "$pod" -c "$CONTAINER_NAME" -- \
              python3 -c "$py" 2>&1)"; then
    fail "python3 invocation failed inside the pod:"
    printf '%s\n' "$out" | sed 's/^/    /'
    return 1
  fi

  printf '%s\n' "$out" | sed 's/^/    /'

  if ! printf '%s' "$out" | grep -q '^cuda available: True'; then
    fail "GPU test FAILED — torch.cuda.is_available() is False"
    return 1
  fi
  local sum
  sum="$(printf '%s' "$out" | awk -F': ' '/^matmul sum:/ {print $2}')"
  if [ -z "$sum" ] || [ "$sum" = "0.0" ] || [ "$sum" = "0" ]; then
    fail "GPU test FAILED — matmul sum is empty or zero ($sum)"
    return 1
  fi
  ok "GPU test PASSED (matmul sum = $sum)"
}

# ---------- subcommand: set-cmd / clear-cmd -------------------------------

# Patch the ConfigMap's PHANTOM_CMD field. Pass the desired value as $1.
# Uses `kubectl patch --type=merge -p <json>` and JSON-escapes the value
# in pure Python to avoid any shell-quoting hazards: the user might pass
# colons, ampersands, dollars, single+double quotes, etc.
patch_phantom_cmd() {
  local value="$1"
  local json
  if ! json="$(VALUE="$value" python3 -c '
import json, os
print(json.dumps({"data": {"PHANTOM_CMD": os.environ["VALUE"]}}))
' 2>/dev/null)"; then
    die "python3 is required to safely build the patch JSON"
  fi

  bold "Patching $CONFIGMAP_NAME with PHANTOM_CMD"
  if [ -z "$value" ]; then
    info "(setting PHANTOM_CMD to empty)"
  else
    info "PHANTOM_CMD = $value"
  fi

  kctl -n "$NAMESPACE" patch cm "$CONFIGMAP_NAME" --type=merge -p "$json"

  bold "Rolling out positronic-control"
  kctl -n "$NAMESPACE" rollout restart deploy/positronic-control

  if [ "$DRY_RUN" = 1 ]; then return 0; fi

  bold "ConfigMap now"
  local cur
  cur="$($KUBECTL -n "$NAMESPACE" get cm "$CONFIGMAP_NAME" \
         -o jsonpath='{.data.PHANTOM_CMD}' 2>/dev/null || true)"
  if [ -z "$cur" ]; then
    info "PHANTOM_CMD: (empty — pod will run sleep infinity)"
  else
    info "PHANTOM_CMD: $cur"
  fi

  printf '\n  next: bash scripts/positronic.sh logs -f\n'
}

cmd_set_cmd() {
  require_kubectl
  if [ $# -eq 0 ]; then
    die "set-cmd needs at least one argument (the command to run inside the pod)"
  fi
  # Join args with single spaces. The user would have typed
  #   set-cmd ros2 launch foo bar.launch.py arg:=value
  # and "$*" reflects that joined verbatim.
  local joined="$*"
  patch_phantom_cmd "$joined"
}

cmd_clear_cmd() {
  require_kubectl
  patch_phantom_cmd ""
}

# ---------- subcommand: push-image ----------------------------------------

# Update the overlay's kustomization.yaml `newTag` for $IMAGE_NAME. The
# entry is matched by exact `name:` value; we fail if it's missing or
# duplicated rather than guessing. Pure-stdlib python so we don't take a
# PyYAML dependency on the robot.
update_overlay_image_tag() {
  local kfile="$1" image_name="$2" new_tag="$3"
  KFILE="$kfile" IMG="$image_name" NEW_TAG="$new_tag" python3 - <<'PY'
import os, re, sys, pathlib
path = pathlib.Path(os.environ["KFILE"])
img = os.environ["IMG"]
new_tag = os.environ["NEW_TAG"]
text = path.read_text()
# Match:  - name: <IMG>\n    newTag: <something>
# Tolerates any leading whitespace before `-` and any indent before newTag.
pattern = re.compile(
    r'(-\s+name:\s*' + re.escape(img) + r'\s*\r?\n\s+newTag:\s*)([^\s\r\n]+)'
)
new_text, count = pattern.subn(lambda m: m.group(1) + new_tag, text)
if count == 0:
    sys.stderr.write(f"no entry for image {img!r} in {path}\n")
    sys.exit(2)
if count > 1:
    sys.stderr.write(f"multiple ({count}) entries for image {img!r} in {path}\n")
    sys.exit(2)
path.write_text(new_text)
PY
}

cmd_push_image() {
  local source="" dest_tag="" skip_redeploy=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag)         [ $# -ge 2 ] || die "--tag needs an argument"
                     dest_tag="$2"; shift 2 ;;
      --no-redeploy) skip_redeploy=1; shift ;;
      -h|--help)     echo "push-image <src> [--tag <dest-tag>] [--no-redeploy]"; return 0 ;;
      --) shift; while [ $# -gt 0 ]; do source="${source:-$1}"; shift; done ;;
      -*) die "unknown push-image flag: $1" ;;
      *)  if [ -z "$source" ]; then source="$1"; else die "unexpected extra arg: $1"; fi
          shift ;;
    esac
  done

  [ -n "$source" ] || die "push-image needs a source image (try: push-image --help)"

  command -v docker >/dev/null 2>&1 || die "docker is required for push-image"

  if [ -z "$dest_tag" ]; then
    case "$source" in
      *@*) die "source uses a digest; pass --tag <dest-tag> explicitly" ;;
      *:*) dest_tag="${source##*:}" ;;
      *)   die "source has no tag; pass --tag <dest-tag> or use <repo>:<tag>" ;;
    esac
  fi

  local target="${IMAGE_NAME}:${dest_tag}"
  local kfile="$OVERLAY/kustomization.yaml"
  [ -f "$kfile" ] || die "overlay kustomization not found: $kfile"

  bold "Source"
  info "$source"
  bold "Target"
  info "$target"

  if [ "$DRY_RUN" = 1 ]; then
    printf '+ docker image inspect %q\n' "$source"
    printf '+ docker tag %q %q\n' "$source" "$target"
    printf '+ docker push %q\n' "$target"
    bold "Would update $kfile"
    info "set newTag=$dest_tag for image $IMAGE_NAME"
  else
    if ! docker image inspect "$source" >/dev/null 2>&1; then
      die "source image not found in local docker: $source"
    fi

    bold "Tagging"
    docker tag "$source" "$target" || die "docker tag failed"
    ok "$source -> $target"

    bold "Pushing $target"
    docker push "$target" || die "docker push failed (registry up? insecure-registries set?)"
    ok "pushed"

    bold "Updating $kfile"
    if ! update_overlay_image_tag "$kfile" "$IMAGE_NAME" "$dest_tag"; then
      die "failed to update overlay's newTag — image was pushed but config is unchanged"
    fi
    ok "newTag = $dest_tag"
  fi

  if [ "$skip_redeploy" = 1 ]; then
    info "skipping redeploy (--no-redeploy)"
    info "next: bash scripts/positronic.sh redeploy"
    return 0
  fi

  if ! resolve_kubectl && [ "$DRY_RUN" != 1 ]; then
    warn "no kubectl backend on this host — overlay updated but pod was not bounced"
    info "next: run 'bash scripts/positronic.sh redeploy' on a host with kubectl"
    return 0
  fi
  cmd_redeploy
}

# ---------- subcommand: redeploy ------------------------------------------

cmd_redeploy() {
  require_kubectl

  if [ ! -d "$OVERLAY" ]; then
    die "overlay directory not found: $OVERLAY"
  fi

  bold "Applying overlay $OVERLAY"
  kctl apply -k "$OVERLAY"

  bold "Bouncing pod"
  kctl -n "$NAMESPACE" delete pod -l "$APP_LABEL" --ignore-not-found

  bold "Watching rollout (Ctrl-C to exit)"
  if [ "$DRY_RUN" = 1 ]; then
    printf '+ %s -n %q rollout status deploy/positronic-control --timeout=120s\n' \
      "$KUBECTL" "$NAMESPACE"
    return 0
  fi
  $KUBECTL -n "$NAMESPACE" rollout status deploy/positronic-control --timeout=120s || true
  $KUBECTL -n "$NAMESPACE" get pod -l "$APP_LABEL" -o wide || true
}

# ---------- subcommand: track-branch --------------------------------------

# Update the targetRevision: line in $1 to $2. Exit 0 if changed,
# 1 if already at the desired value, 2 on parse error.
_update_target_revision() {
  FILE="$1" BRANCH="$2" python3 - <<'PY'
import os, re, sys, pathlib
path = pathlib.Path(os.environ["FILE"])
br = os.environ["BRANCH"]
text = path.read_text()
pattern = re.compile(r'(targetRevision:\s*)([^\s\r\n]+)')
m = pattern.search(text)
if not m:
    sys.stderr.write(f"no targetRevision: line in {path}\n")
    sys.exit(2)
if m.group(2) == br:
    sys.exit(1)  # no-op
new_text = pattern.sub(lambda x: x.group(1) + br, text, count=1)
path.write_text(new_text)
PY
}

cmd_track_branch() {
  local branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) echo "track-branch [<branch>]"; return 0 ;;
      -*) die "unknown track-branch flag: $1" ;;
      *)  if [ -z "$branch" ]; then branch="$1"; else die "unexpected extra arg: $1"; fi
          shift ;;
    esac
  done

  if [ -z "$branch" ]; then
    branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
      die "could not determine current git branch — pass <branch> explicitly"
    fi
  fi

  command -v git >/dev/null 2>&1 || die "git is required for track-branch"
  [ -f "$TRACK_APP_FILE" ] || die "Application file not found: $TRACK_APP_FILE"

  bold "Pointing $TRACK_ROOT_APP at branch: $branch"

  # 1. Edit the Application file in place.
  local edit_rc=0
  if [ "$DRY_RUN" = 1 ]; then
    info "would set targetRevision=$branch in $TRACK_APP_FILE"
  else
    _update_target_revision "$TRACK_APP_FILE" "$branch" || edit_rc=$?
    case "$edit_rc" in
      0) ok "$TRACK_APP_FILE — targetRevision: $branch" ;;
      1) info "$TRACK_APP_FILE already at targetRevision: $branch" ;;
      *) die "failed to update $TRACK_APP_FILE" ;;
    esac
  fi

  # 2. Commit + push the file (only if it actually changed).
  if [ "$edit_rc" = 0 ] && [ "$DRY_RUN" != 1 ]; then
    bold "Committing + pushing $TRACK_APP_FILE"
    local cur_branch
    cur_branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    git -C "$REPO" add "$TRACK_APP_FILE" || die "git add failed"
    git -C "$REPO" commit -m "gitops: track $branch on $ARGO_APP" -- "$TRACK_APP_FILE" \
      || die "git commit failed"
    git -C "$REPO" push -u origin "$cur_branch" || die "git push failed"
    ok "pushed to origin/$cur_branch"
  fi

  # 3. Patch the live root Application's targetRevision.
  bold "Patching live $TRACK_ROOT_APP.spec.source.targetRevision -> $branch"
  require_kubectl
  local payload
  if ! payload="$(BRANCH="$branch" python3 -c '
import json, os
print(json.dumps({"spec": {"source": {"targetRevision": os.environ["BRANCH"]}}}))
' 2>/dev/null)"; then
    die "python3 is required to build the patch JSON"
  fi
  kctl -n "$TRACK_ROOT_NS" patch app "$TRACK_ROOT_APP" --type=merge -p "$payload" \
    || die "failed to patch live $TRACK_ROOT_APP Application"

  if [ "$DRY_RUN" = 1 ]; then return 0; fi

  ok "$TRACK_ROOT_APP -> $branch"

  bold "Next"
  info "ArgoCD reconciles within ~3 min, or trigger now:"
  info "  $KUBECTL -n $TRACK_ROOT_NS annotate app $TRACK_ROOT_APP \\"
  info "    argocd.argoproj.io/refresh=hard --overwrite"
  info ""
  info "Heads up: any uncommitted changes under manifests/ aren't on the branch"
  info "yet — commit + push them before ArgoCD reconciles, or it will pull the"
  info "previous tree."
  info ""
  info "Flip back: bash scripts/positronic.sh track-branch main"
}

# ---------- subcommand: argo-pause / argo-resume --------------------------

cmd_argo_pause() {
  require_kubectl
  bold "Disabling ArgoCD selfHeal on $ARGO_NS/$ARGO_APP"
  info "auto-sync stays ON; cluster drift won't be reverted by ArgoCD."
  kctl -n "$ARGO_NS" patch app "$ARGO_APP" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":true}}}}' \
    || die "patch failed"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  ok "$ARGO_APP selfHeal=false"
  info "you can now: kubectl apply -k <overlay> (sticks until next git change)"
  info "resume: bash scripts/positronic.sh argo-resume"
}

cmd_argo_resume() {
  require_kubectl
  bold "Re-enabling ArgoCD selfHeal on $ARGO_NS/$ARGO_APP"
  kctl -n "$ARGO_NS" patch app "$ARGO_APP" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}' \
    || die "patch failed"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  ok "$ARGO_APP selfHeal=true"
  info "ArgoCD will revert any cluster-side drift on the next reconcile."
}

# ---------- subcommand: teardown ------------------------------------------

cmd_teardown() {
  require_kubectl
  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) yes=1; shift ;;
      -h|--help) echo "teardown [-y|--yes]"; return 0 ;;
      *) die "unknown teardown flag: $1" ;;
    esac
  done

  bold "Teardown plan"
  cat <<EOF
    delete deploy/positronic-control   in ns/$NAMESPACE
    delete cm/$CONFIGMAP_NAME           in ns/$NAMESPACE
    delete namespace/$NAMESPACE
    (manifest files in $REPO are NOT touched)
EOF

  if [ "$yes" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf '\nProceed? [y/N] '
    local ans
    read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES) ;;
      *) info "aborted."; return 0 ;;
    esac
  fi

  kctl -n "$NAMESPACE" delete deploy positronic-control --ignore-not-found
  kctl -n "$NAMESPACE" delete cm "$CONFIGMAP_NAME" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  ok "teardown complete"
}

# ---------- arg parsing / dispatch ----------------------------------------

# Pull off global flags up to (but not including) the first non-flag token,
# which we treat as the subcommand. After that we hand the rest to the
# subcommand verbatim so that semantics like `exec -- bash -c '...'` work.
sub=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --robot)   ROBOT="${2:-}"; [ -n "$ROBOT" ] || die "--robot requires a name"; shift 2 ;;
    -h|--help) cmd_help; exit 0 ;;
    -*) die "unknown global flag: $1 (try: $0 help)" ;;
    *) sub="$1"; shift; break ;;
  esac
done

_resolve_robot

if [ -z "$sub" ]; then
  cmd_help
  exit 0
fi

# Allow --dry-run between the subcommand and its args, but only as the
# very first arg — once the user starts typing payload args (especially
# anything after `--`) we leave the rest alone.
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

case "$sub" in
  help|-h|--help) cmd_help ;;
  status)         cmd_status         "$@" ;;
  logs)           cmd_logs           "$@" ;;
  exec)           cmd_exec           "$@" ;;
  gpu-test)       cmd_gpu_test       "$@" ;;
  set-cmd)        cmd_set_cmd        "$@" ;;
  clear-cmd)      cmd_clear_cmd      "$@" ;;
  push-image)     cmd_push_image     "$@" ;;
  redeploy)       cmd_redeploy       "$@" ;;
  track-branch)   cmd_track_branch   "$@" ;;
  argo-pause)     cmd_argo_pause     "$@" ;;
  argo-resume)    cmd_argo_resume    "$@" ;;
  teardown)       cmd_teardown       "$@" ;;
  *) die "unknown subcommand: $sub (try: $0 help)" ;;
esac
