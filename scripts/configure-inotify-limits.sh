#!/usr/bin/env bash
# configure-inotify-limits.sh
#
# Installs a sysctl drop-in raising the kernel inotify limits on the
# host. The stock default fs.inotify.max_user_instances = 128 gets
# exhausted as the number of k8s workloads grows (gaia stack + more
# pods, each watcher/SDK opening its own inotify instances). On
# mk11000020 root already held 127 inotify instances and mediamtx
# crashed at startup with:
#   couldn't initialize inotify: too many open files
#
# Raising max_user_instances (and max_user_watches for headroom) fixes
# this for every workload on the host, not just mediamtx.
#
# Harmless and host-wide: the values are upper bounds, so a host that
# never approaches them is unaffected.
#
# One-time per robot. Idempotent — re-running with the drop-in already
# in place is a no-op (file content compared byte-for-byte).
#
# Usage:
#   sudo bash scripts/configure-inotify-limits.sh
#

set -eu

SYSCTL_DIR=/etc/sysctl.d
CONF_FILE="$SYSCTL_DIR/99-inotify.conf"

read -r -d '' CONF_CONTENT <<'EOF' || true
# Raise inotify limits so the growing set of k8s workloads (gaia stack,
# mediamtx, and friends) doesn't exhaust the stock 128-instance default.
# Installed by Phantom-OS-KubernetesOptions bootstrap
# (scripts/configure-inotify-limits.sh). Re-run that script after editing.
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
EOF

if [ -r "$CONF_FILE" ] && [ "$(cat "$CONF_FILE")" = "$CONF_CONTENT" ]; then
  echo "sysctl drop-in already present at $CONF_FILE — no-op"
  exit 0
fi

mkdir -p "$SYSCTL_DIR"
if [ -e "$CONF_FILE" ]; then
  cp -p "$CONF_FILE" "$CONF_FILE.bak.$(date +%Y%m%d-%H%M%S)"
fi
printf '%s\n' "$CONF_CONTENT" > "$CONF_FILE"
chmod 644 "$CONF_FILE"
echo "wrote $CONF_FILE"

# Apply the new limits to the running kernel. Apply ONLY our drop-in
# (not `sysctl --system`): --system re-applies every drop-in on the host,
# and on some kernels (e.g. Tegra/Jetson) an unrelated pre-existing
# drop-in sets a key the kernel doesn't expose (e.g.
# net.core.default_qdisc). `sysctl --system` returns non-zero on that,
# which would fail this script and halt bootstrap before gitops. Loading
# just our file sets the inotify limits without depending on the rest of
# the host's sysctl tree.
sysctl -p "$CONF_FILE" >/dev/null 2>&1 || true
echo "applied inotify limits:"
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
