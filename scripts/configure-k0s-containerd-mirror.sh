#!/usr/bin/env bash
# configure-k0s-containerd-mirror.sh
#
# One-time per-robot host-level bootstrap. Makes k0s's containerd + the
# host's docker daemon use http://localhost:5000 as a priority-first
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

REGISTRY_HOST="${REGISTRY_HOST:-localhost:5000}"
UPSTREAM_URL="${UPSTREAM_URL:-https://registry-1.docker.io}"
HOSTS_DIR="${HOSTS_DIR:-/etc/k0s/containerd.d/hosts}"
CONTAINERD_IMPORT="${CONTAINERD_IMPORT:-/etc/k0s/containerd.d/10-registry-mirror.toml}"
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
# refused. `override_path = true` is required when the first mirror is a
# pull-through cache that serves all repos at its root path.

echo "==> writing ${HOSTS_DIR}/docker.io/hosts.toml"
mkdir -p "${HOSTS_DIR}/docker.io"
backup "${HOSTS_DIR}/docker.io/hosts.toml"
cat > "${HOSTS_DIR}/docker.io/hosts.toml" <<EOF
# Managed by scripts/configure-k0s-containerd-mirror.sh
# containerd resolves docker.io/* by trying these hosts in declaration order.
# On 404 or connection failure, it falls through to the next host.

server = "${UPSTREAM_URL}"

[host."http://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true

[host."${UPSTREAM_URL}"]
  capabilities = ["pull", "resolve"]
EOF

# --- 2. containerd config import ------------------------------------------
# k0s reads /etc/k0s/containerd.d/*.toml as drop-in imports that extend
# its generated containerd.toml. We need to point the CRI registry plugin
# at the hosts directory above.

echo "==> writing ${CONTAINERD_IMPORT}"
mkdir -p "$(dirname "${CONTAINERD_IMPORT}")"
backup "${CONTAINERD_IMPORT}"
cat > "${CONTAINERD_IMPORT}" <<EOF
# Managed by scripts/configure-k0s-containerd-mirror.sh
# Tells containerd's CRI plugin to look for registry mirror config
# (hosts.toml files) under ${HOSTS_DIR}.

version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "${HOSTS_DIR}"
EOF

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
