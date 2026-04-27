#!/usr/bin/env bash
# configure-k0s-containerd-mirror.sh
#
# One-time per-robot host-level bootstrap. Makes k0s's containerd + the
# host's docker daemon use http://localhost:5443 as a priority-first
# mirror for DockerHub, with registry-1.docker.io as fallback.
#
# Idempotent — safe to re-run. Backs up any file it overwrites to
# <file>.bak.<timestamp> before writing.
#
# Usage:   sudo bash scripts/configure-k0s-containerd-mirror.sh
#
# Then validate with:
#          sudo bash scripts/validate-local-registry.sh
#
# This is the host-level half of the registry rollout. The cluster-level
# half (the registry pod itself) is deployed by ArgoCD from
# manifests/base/registry/ — no action needed once this repo is checked
# out on the robot and ArgoCD is running.

set -euo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-localhost:5443}"
UPSTREAM_URL="${UPSTREAM_URL:-https://registry-1.docker.io}"
HOSTS_DIR="${HOSTS_DIR:-/etc/k0s/containerd.d/hosts}"
CONTAINERD_IMPORT_DIR="${CONTAINERD_IMPORT_DIR:-/etc/k0s/containerd.d}"
CONTAINERD_IMPORT="${CONTAINERD_IMPORT:-${CONTAINERD_IMPORT_DIR}/10-registry-mirror.toml}"
CONTAINERD_CONFIG="${CONTAINERD_CONFIG:-/etc/k0s/containerd.toml}"
DAEMON_JSON="${DAEMON_JSON:-/etc/docker/daemon.json}"

if [ "$(id -u)" -ne 0 ]; then
  echo "error: must run as root (try: sudo bash $0)" >&2
  exit 2
fi

timestamp="$(date +%Y%m%d-%H%M%S)"

backup() {
  # backup <file>  — if file exists, copy to <file>.bak.<ts>
  local f="$1"
  if [ -e "$f" ]; then
    cp -a "$f" "${f}.bak.${timestamp}"
    echo "  backed up ${f} -> ${f}.bak.${timestamp}"
  fi
}

# --- 1. containerd hosts.toml ---------------------------------------------
# Priority-ordered mirror config. containerd iterates [host."..."] blocks
# in declaration order on every pull, falling through on 404 / connection
# refused. The local registry is a plain Distribution registry serving at
# /v2/<repo>/... — i.e. the standard layout — so we do NOT set
# `override_path = true`. That flag is for pull-through caches that
# expose images at root paths; setting it against /v2/-style registry
# makes containerd send manifest requests without the /v2/ prefix and
# every pull silently 404s back to the upstream fallthrough.
#
# Host order is (upstream, local) — see the heredoc comment below.

echo "==> writing ${HOSTS_DIR}/docker.io/hosts.toml"
mkdir -p "${HOSTS_DIR}/docker.io"
backup "${HOSTS_DIR}/docker.io/hosts.toml"
cat > "${HOSTS_DIR}/docker.io/hosts.toml" <<EOF
# Managed by scripts/configure-k0s-containerd-mirror.sh
# containerd resolves docker.io/* by trying these hosts in declaration order.
# On 404 or connection failure, it falls through to the next host.
#
# Order is (upstream, local):
#   - Online: tag->digest resolution and blob pulls go to DockerHub first.
#     The local registry never serves a stale tag and is consulted only
#     as a fallback (DockerHub unreachable / 404).
#   - Offline: containerd's request to DockerHub fails on connect, falls
#     through to ${REGISTRY_HOST}. As long as the image was primed (or
#     pushed) into the local registry beforehand, deploys keep working.
#
# Tradeoff: when DockerHub IS reachable, blob bytes also come from
# upstream — the local registry's role shrinks to "offline blob store."
# That's accepted: the alternative (local first) re-introduces the
# stale-tag footgun.

server = "${UPSTREAM_URL}"

[host."${UPSTREAM_URL}"]
  capabilities = ["pull", "resolve"]

[host."http://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# --- 2. containerd config import ------------------------------------------
# Two-step: (a) write a drop-in TOML under /etc/k0s/containerd.d/ that
# carries the config_path pointing at HOSTS_DIR, then (b) ensure the main
# containerd config has an `imports` line that pulls those drop-ins in.
# k0s does NOT auto-import /etc/k0s/containerd.d/*.toml — the imports
# directive has to be present in /etc/k0s/containerd.toml itself.

echo "==> writing ${CONTAINERD_IMPORT}"
mkdir -p "$(dirname "${CONTAINERD_IMPORT}")"
backup "${CONTAINERD_IMPORT}"
cat > "${CONTAINERD_IMPORT}" <<EOF
# Managed by scripts/configure-k0s-containerd-mirror.sh
# Pulled into containerd's main config via the `imports` line in
# ${CONTAINERD_CONFIG} (also added by this script).

version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "${HOSTS_DIR}"
EOF

echo "==> ensuring imports line in ${CONTAINERD_CONFIG}"
if [ ! -e "${CONTAINERD_CONFIG}" ]; then
  echo "  ${CONTAINERD_CONFIG} not found — k0s may not have written it yet." >&2
  echo "  Start k0s once (sudo systemctl start k0scontroller) so it generates" >&2
  echo "  the file, then re-run this script." >&2
  exit 1
fi
backup "${CONTAINERD_CONFIG}"
python3 - "${CONTAINERD_CONFIG}" "${CONTAINERD_IMPORT_DIR}" <<'PY'
import sys, glob, re
path, import_dir = sys.argv[1], sys.argv[2]
content = open(path).read()
glob_path = f"{import_dir}/*.toml"
import_line = f'imports = ["{glob_path}"]'

# Top-level keys live above the first [section] header. Anything under a
# [section] is scoped to that section and won't act as a top-level import.
top_level, sep, rest = content.partition('\n[')

# Already present?
if re.search(r'^imports\s*=', top_level, flags=re.M):
    # Make sure our glob is in the existing list.
    m = re.search(r'^imports\s*=\s*(\[[^\]]*\])', top_level, flags=re.M)
    if m and glob_path not in m.group(1):
        new_list = m.group(1).rstrip(']').rstrip() + f', "{glob_path}"]'
        top_level = top_level[:m.start(1)] + new_list + top_level[m.end(1):]
        open(path, 'w').write(top_level + (sep + rest if sep else ''))
        print(f"  appended {glob_path} to existing imports list")
    else:
        print("  imports line already includes our glob — no change")
    sys.exit(0)

# Insert imports as a new top-level key right before the first section.
new_top = top_level.rstrip() + '\n' + import_line + '\n'
open(path, 'w').write(new_top + (sep + rest if sep else ''))
print(f"  inserted: {import_line}")
PY

# --- 3. docker daemon.json (for host-side docker push) --------------------
# The host's docker daemon needs to know ${REGISTRY_HOST} is OK to push
# to over plain HTTP. Merge into any existing daemon.json rather than
# clobber it.

if command -v docker >/dev/null 2>&1; then
  echo "==> updating ${DAEMON_JSON}"
  mkdir -p "$(dirname "${DAEMON_JSON}")"
  backup "${DAEMON_JSON}"
  python3 - "$DAEMON_JSON" "$REGISTRY_HOST" <<'PY'
import json, os, sys
path, host = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        raw = f.read().strip()
        if raw:
            cfg = json.loads(raw)
regs = cfg.get("insecure-registries", [])
if host not in regs:
    regs.append(host)
cfg["insecure-registries"] = regs
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  insecure-registries now: {regs}")
PY
else
  echo "==> docker not installed — skipping ${DAEMON_JSON}"
fi

# --- 4. restart services --------------------------------------------------

echo "==> restarting docker (if installed)"
if systemctl list-unit-files docker.service >/dev/null 2>&1; then
  systemctl restart docker
  echo "  docker restarted"
else
  echo "  docker not managed by systemd — skipping"
fi

echo "==> restarting k0s"
# k0s ships as either k0scontroller (single-node controller+worker) or
# k0sworker. Restart whichever is present.
restarted=0
for unit in k0scontroller k0sworker; do
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
    systemctl restart "$unit"
    echo "  ${unit} restarted"
    restarted=1
  fi
done
if [ "$restarted" = 0 ]; then
  echo "  no k0s systemd unit found — if k0s is installed via a different mechanism," >&2
  echo "  restart it manually so the containerd config takes effect." >&2
fi

echo
echo "==> done. validate with:"
echo "    sudo bash $(dirname "$0")/validate-local-registry.sh"
