# ops-prompt.sh — TUI-aware prompt + status helpers.
#
# When sourced in a script run under `phantomos-ops`, the helpers emit
# structured JSON events on fd 3 and read user replies from stdin.
# The TUI translates events into native widgets — phase headers,
# coloured status bullets, Input modals for ask, Yes/No modals for
# confirm — and feeds the operator's answer back as a single line on
# the script's stdin.
#
# When sourced in a script run from a plain shell (no fd 3), the same
# helpers fall back to `read` / `printf` so the script keeps working
# from cron, systemd, ssh, etc.
#
# This is the bridge layer. Existing scripts gradually migrate by
# replacing bare `read -p "..." VAR` with `VAR="$(op_ask field 'label')"`,
# and bare `echo "  PASS  msg"` with `op_pass "msg"` — without
# breaking plain-shell use.
#
# Usage:
#   . "$(dirname "$0")/lib/ops-prompt.sh"
#
#   op_phase "Preflight"
#   op_pass  "OS: Ubuntu 24.04"
#   op_skip  "port 6443 held by kube-apiserver"
#   op_warn  "GPU unavailable"
#   op_fail  "/etc/dma/dma-ethercat.env missing"
#
#   ROBOT="$(op_ask robot_name 'Robot name?' 'hwthor01')"
#   if op_confirm 'Wipe cluster state?' false; then …; fi

# ---- bridge detection ---------------------------------------------------

# True iff fd 3 is open + writable. (printf '' >&3) is the cheapest
# probe — it succeeds with no side-effect when the fd is wired up by
# the TUI, fails silently otherwise.
if (printf '' >&3) 2>/dev/null; then
  _OPS_TUI=1
else
  _OPS_TUI=0
fi

# ---- JSON encoding ------------------------------------------------------
#
# We need JSON for the bridge but want to avoid forcing every robot to
# install jq. Use python3 — already a hard dep on Jetson Ubuntu and
# everywhere else this code runs (host-config.py needs it).

_op_json_encode() {
  python3 -c '
import json, sys
print(json.dumps({k: v for k, v in (a.split("=", 1) for a in sys.argv[1:])}))
' "$@"
}

_op_emit() {
  # All args are key=value pairs; encoded as a single JSON object.
  if [ "$_OPS_TUI" = 1 ]; then
    _op_json_encode "$@" >&3
  fi
}

# ---- phase + status -----------------------------------------------------

op_phase() {
  local title="$1"
  if [ "$_OPS_TUI" = 1 ]; then
    _op_emit "event=phase" "title=$title"
  else
    printf '\n== %s ==\n' "$title"
  fi
}

_op_status() {
  local level="$1"; shift
  local msg="$*"
  if [ "$_OPS_TUI" = 1 ]; then
    _op_emit "event=status" "level=$level" "msg=$msg"
  else
    case "$level" in
      pass) printf '  ✓ PASS  %s\n' "$msg" ;;
      warn) printf '  ! WARN  %s\n' "$msg" ;;
      fail) printf '  ✗ FAIL  %s\n' "$msg" ;;
      skip) printf '  • SKIP  %s\n' "$msg" ;;
      *)    printf '  - %s\n' "$msg" ;;
    esac
  fi
}

op_pass() { _op_status pass "$@"; }
op_warn() { _op_status warn "$@"; }
op_fail() { _op_status fail "$@"; }
op_skip() { _op_status skip "$@"; }

# ---- prompts ------------------------------------------------------------

# op_ask <field> <label> [default]
# Prints the operator's answer on stdout. Caller captures with $().
op_ask() {
  _op_ask_kind string "$@"
}

# op_ask_password <field> <label> [default]
# Same as op_ask but the TUI renders a masked input; falls back to
# `read -s` (no echo) in plain shell mode.
op_ask_password() {
  _op_ask_kind password "$@"
}

_op_ask_kind() {
  local kind="$1" field="$2" label="$3" default="${4:-}"
  if [ "$_OPS_TUI" = 1 ]; then
    _op_emit "event=ask" "field=$field" "label=$label" "default=$default" "kind=$kind"
    local reply
    IFS= read -r reply
    if [ -z "$reply" ] && [ -n "$default" ]; then
      reply="$default"
    fi
    printf '%s' "$reply"
  else
    local reply
    if [ "$kind" = password ]; then
      # -s suppresses echo; works under bash + zsh + dash.
      if [ -n "$default" ]; then
        read -r -s -p "$label [default]: " reply
      else
        read -r -s -p "$label: " reply
      fi
      printf '\n' >&2
      reply="${reply:-$default}"
    elif [ -n "$default" ]; then
      read -r -p "$label [$default]: " reply
      reply="${reply:-$default}"
    else
      read -r -p "$label: " reply
    fi
    printf '%s' "$reply"
  fi
}

# op_confirm <label> [default=false]
# Returns 0 (yes) or 1 (no).
op_confirm() {
  local label="$1" default="${2:-false}"
  if [ "$_OPS_TUI" = 1 ]; then
    _op_emit "event=confirm" "label=$label" "default=$default"
    local reply
    IFS= read -r reply
    case "$reply" in y|Y|yes|true) return 0 ;; *) return 1 ;; esac
  else
    local hint reply
    [ "$default" = true ] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$label $hint: " reply
    if [ -z "$reply" ]; then
      [ "$default" = true ] && return 0 || return 1
    fi
    case "$reply" in y|Y|yes|true) return 0 ;; *) return 1 ;; esac
  fi
}
