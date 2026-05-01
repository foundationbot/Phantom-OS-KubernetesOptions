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
#   3. $(hostname) if it matches manifests/robots/<name>/
#
# If none resolve and the caller is not running interactively, callers
# should fail with the message produced by resolve_robot.
#
# Required globals before sourcing:
#   REPO_ROOT   absolute path to the Phantom-OS-KubernetesOptions repo
# Optional:
#   ROBOT_ID_FILE   override the default /etc/phantomos/robot path

ROBOT_ID_FILE="${ROBOT_ID_FILE:-/etc/phantomos/robot}"

# resolve_robot <flag-value>
#
# Echoes the resolved robot name to stdout. Returns 0 on success, 1 on
# failure (no name resolved or overlay dir missing). On failure, prints
# a diagnostic to stderr — caller should exit.
resolve_robot() {
  local flag="${1:-}"
  local name=""

  if [ -n "$flag" ]; then
    name="$flag"
  elif [ -r "$ROBOT_ID_FILE" ]; then
    name="$(head -n1 "$ROBOT_ID_FILE" | tr -d '[:space:]')"
  else
    local hn
    hn="$(hostname 2>/dev/null || true)"
    if [ -n "$hn" ] && [ -d "${REPO_ROOT:?REPO_ROOT must be set}/manifests/robots/$hn" ]; then
      name="$hn"
    fi
  fi

  if [ -z "$name" ]; then
    local available
    available="$(ls -1 "$REPO_ROOT/manifests/robots/" 2>/dev/null | tr '\n' ' ')"
    printf 'error: could not determine robot identity.\n' >&2
    printf '  no --robot flag, %s missing, hostname does not match an overlay.\n' "$ROBOT_ID_FILE" >&2
    printf '  available overlays: %s\n' "${available:-<none>}" >&2
    printf '  first bringup: re-run with --robot <name> to persist.\n' >&2
    return 1
  fi

  if [ ! -d "$REPO_ROOT/manifests/robots/$name" ]; then
    local available
    available="$(ls -1 "$REPO_ROOT/manifests/robots/" 2>/dev/null | tr '\n' ' ')"
    printf 'error: manifests/robots/%s/ not found — typo? available: %s\n' \
      "$name" "${available:-<none>}" >&2
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
