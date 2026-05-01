#!/usr/bin/env bash
# robot-id.sh — shared helper for resolving and persisting robot identity.
#
# Sourced by scripts/bootstrap-robot.sh and scripts/positronic.sh (and any
# other script that needs to know which robot it is operating on). Robot
# identity lives at /etc/phantomos/robot on the host so it only has to be
# supplied once, at first bringup.
#
# Resolution order (first hit wins):
#   1. explicit name passed in by the caller (their --robot flag value)
#   2. /etc/phantomos/robot                  — written by bootstrap
#   3. /etc/phantomos/host-config.yaml's `robot:` field
#   4. $(hostname) if it looks like a valid robot name
#
# A "valid robot name" is DNS-1123: lowercase alphanumeric + hyphens,
# 1..63 chars, starting and ending with alphanumeric. The name flows
# into Argo Application metadata.name (e.g. phantomos-mk09-core), which
# Kubernetes requires to be DNS-1123. There is NO filesystem check —
# robot identity is no longer tied to a manifests/robots/<name>/ tree.
# Operators choose names; no central registry beyond the host file.
#
# Required globals before sourcing:
#   REPO_ROOT   absolute path to the Phantom-OS-KubernetesOptions repo
# Optional:
#   ROBOT_ID_FILE       override the default /etc/phantomos/robot path
#   HOST_CONFIG_FILE    override the default /etc/phantomos/host-config.yaml path

ROBOT_ID_FILE="${ROBOT_ID_FILE:-/etc/phantomos/robot}"

# resolve_robot <flag-value>
#
# Echoes the resolved robot name to stdout. Returns 0 on success, 1 on
# failure (no name resolved or overlay dir missing). On failure, prints
# a diagnostic to stderr — caller should exit.
HOST_CONFIG_FILE_DEFAULT="${HOST_CONFIG_FILE:-/etc/phantomos/host-config.yaml}"

# DNS-1123: ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$
_robot_name_valid() {
  local v="$1"
  [ -z "$v" ] && return 1
  printf '%s' "$v" | grep -Eq '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
}

resolve_robot() {
  local flag="${1:-}"
  local name=""

  if [ -n "$flag" ]; then
    name="$flag"
  elif [ -r "$ROBOT_ID_FILE" ]; then
    name="$(head -n1 "$ROBOT_ID_FILE" | tr -d '[:space:]')"
  elif [ -r "$HOST_CONFIG_FILE_DEFAULT" ] \
       && command -v python3 >/dev/null 2>&1 \
       && [ -f "${REPO_ROOT:?REPO_ROOT must be set}/scripts/lib/host-config.py" ]; then
    name="$(python3 "$REPO_ROOT/scripts/lib/host-config.py" \
              "$HOST_CONFIG_FILE_DEFAULT" get robot 2>/dev/null || true)"
  fi

  if [ -z "$name" ]; then
    local hn
    hn="$(hostname 2>/dev/null || true)"
    if [ -n "$hn" ]; then name="$hn"; fi
  fi

  # Robot names are lowercase by convention. Normalize so --robot
  # MK11000010 and --robot mk11000010 both work.
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$name" ]; then
    printf 'error: could not determine robot identity.\n' >&2
    printf '  no --robot flag, %s missing, host-config.yaml empty, hostname empty.\n' "$ROBOT_ID_FILE" >&2
    printf '  first bringup: re-run with --robot <name> to persist.\n' >&2
    return 1
  fi

  if ! _robot_name_valid "$name"; then
    printf 'error: robot name %q is not DNS-1123.\n' "$name" >&2
    printf '  rules: lowercase alphanumeric and hyphens; 1..63 chars;\n' >&2
    printf '  must start and end with alphanumeric.\n' >&2
    return 1
  fi

  printf '%s\n' "$name"
}

# persist_robot <name>
#
# Writes the robot name to ROBOT_ID_FILE (creating the parent directory).
# Idempotent. No-op (with a single-line skip notice) if the file already
# contains the same name. Caller is responsible for being root.
persist_robot() {
  local name="${1:?persist_robot: name required}"
  local dir
  dir="$(dirname "$ROBOT_ID_FILE")"

  if [ -r "$ROBOT_ID_FILE" ]; then
    local current
    current="$(head -n1 "$ROBOT_ID_FILE" | tr -d '[:space:]')"
    if [ "$current" = "$name" ]; then
      return 0
    fi
  fi

  mkdir -p "$dir"
  printf '%s\n' "$name" > "$ROBOT_ID_FILE"
  chmod 0644 "$ROBOT_ID_FILE"
}
