#!/usr/bin/env bash
# configure-k0s-nvidia-runtime.sh
#
# Registers the nvidia container runtime with k0s's containerd so pods
# can request GPU access via `runtimeClassName: nvidia`. Without this,
# pods get the host's /dev/nvidia* device nodes (via /dev mount +
# privileged) but NOT the userspace driver libraries that
# nvidia-container-runtime would normally bind-mount in — so anything
# that calls into libcuda.so / libnvidia-* fails.
#
# One-time per robot. Idempotent. Backs up any file it overwrites.
#
# Usage:
#   sudo bash scripts/configure-k0s-nvidia-runtime.sh
#
# Then validate:
#   sudo k0s kubectl get runtimeclass nvidia
#   sudo bash scripts/diagnose-positronic.sh
#
# Prerequisites:
#   - nvidia-container-toolkit installed on the host
#     (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
#   - /usr/bin/nvidia-container-runtime exists and runs
#
# Companion of:
#   - scripts/configure-k0s-containerd-mirror.sh — registers the
#     local-registry mirror in containerd.
#   - manifests/base/runtime-classes/nvidia.yaml — Kubernetes
#     RuntimeClass that names this handler.

set -euo pipefail

CONTAINERD_IMPORT_DIR="${CONTAINERD_IMPORT_DIR:-/etc/k0s/containerd.d}"
CONTAINERD_IMPORT="${CONTAINERD_IMPORT:-${CONTAINERD_IMPORT_DIR}/20-nvidia-runtime.toml}"
CONTAINERD_CONFIG="${CONTAINERD_CONFIG:-/etc/k0s/containerd.toml}"
NVIDIA_RUNTIME="${NVIDIA_RUNTIME:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "error: must run as root (try: sudo bash $0)" >&2
  exit 2
fi

# Auto-detect the runtime binary if not provided.
if [ -z "$NVIDIA_RUNTIME" ]; then
  for candidate in \
      /usr/bin/nvidia-container-runtime \
      /usr/local/bin/nvidia-container-runtime \
      /usr/local/nvidia/toolkit/nvidia-container-runtime; do
    if [ -x "$candidate" ]; then
      NVIDIA_RUNTIME="$candidate"
      break
    fi
  done
fi

if [ -z "$NVIDIA_RUNTIME" ] || [ ! -x "$NVIDIA_RUNTIME" ]; then
  echo "error: nvidia-container-runtime not found." >&2
  echo "Install nvidia-container-toolkit first:" >&2
  echo "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html" >&2
  echo "Or set NVIDIA_RUNTIME=/path/to/nvidia-container-runtime explicitly." >&2
  exit 1
fi

echo "==> using $NVIDIA_RUNTIME"
"$NVIDIA_RUNTIME" --version 2>&1 | sed 's/^/    /' || true

timestamp="$(date +%Y%m%d-%H%M%S)"
backup() {
  local f="$1"
  if [ -e "$f" ]; then
    cp -a "$f" "${f}.bak.${timestamp}"
    echo "  backed up ${f} -> ${f}.bak.${timestamp}"
  fi
}

# Determine the containerd config version to emit. containerd 2.x (shipped
# by k0s >= 1.36) requires config `version = 3` and renamed the CRI plugin
# (runtimes live under io.containerd.cri.v1.runtime); containerd 1.7.x
# (k0s 1.35.x) uses `version = 2` and io.containerd.grpc.v1.cri. Emitting
# the wrong one makes k0s reject the drop-in at pre-flight and crash-loop.
# Prefer the version k0s already declared in its generated main config
# (authoritative); fall back to the bundled containerd binary's major.
containerd_config_version() {
  local v ctr major
  if [ -r "${CONTAINERD_CONFIG}" ]; then
    v="$(grep -oE '^[[:space:]]*version[[:space:]]*=[[:space:]]*[0-9]+' "${CONTAINERD_CONFIG}" 2>/dev/null \
          | grep -oE '[0-9]+' | head -1)"
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  fi
  for ctr in /var/lib/k0s/bin/containerd "$(command -v containerd 2>/dev/null || true)"; do
    if [ -z "$ctr" ] || [ ! -x "$ctr" ]; then continue; fi
    major="$("$ctr" --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
              | sed -E 's/^v//; s/\..*//')"
    if [ -n "$major" ]; then [ "$major" -ge 2 ] && printf '3' || printf '2'; return; fi
  done
  printf '2'
}

# --- 1. Drop-in TOML registering the runtime --------------------------------

CFG_VERSION="$(containerd_config_version)"
if [ "$CFG_VERSION" = 3 ]; then
  RUNTIMES_TABLE='[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]'
  RUNTIMES_OPTIONS_TABLE='  [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]'
else
  RUNTIMES_TABLE='[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]'
  RUNTIMES_OPTIONS_TABLE='  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]'
fi

echo "==> writing ${CONTAINERD_IMPORT} (containerd config version ${CFG_VERSION})"
mkdir -p "$(dirname "${CONTAINERD_IMPORT}")"
backup "${CONTAINERD_IMPORT}"
cat > "${CONTAINERD_IMPORT}" <<EOF
# Managed by scripts/configure-k0s-nvidia-runtime.sh
# Registers the nvidia container runtime as a containerd runtime named
# "nvidia". Pods that set runtimeClassName: nvidia will be started via
# this runtime, which bind-mounts host driver libraries + Tegra device
# bits into the container.
#
# Format tracks the bundled containerd: version 3 +
# io.containerd.cri.v1.runtime for containerd 2.x (k0s >= 1.36), or
# version 2 + io.containerd.grpc.v1.cri for containerd 1.7.x (k0s 1.35.x).

version = ${CFG_VERSION}

${RUNTIMES_TABLE}
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false
  # Don't set SystemdCgroup here. k0s's default runc runtime uses
  # cgroupfs; setting this runtime to systemd cgroups creates a
  # mismatch with the kubelet (which provides cgroupfs paths) and
  # the pod fails sandbox creation with "expected cgroupsPath to be
  # of format slice:prefix:name". Inherit the cluster default.
${RUNTIMES_OPTIONS_TABLE}
    BinaryName = "${NVIDIA_RUNTIME}"
EOF

# --- 2. Confirm imports line is present in the main containerd config -----
# configure-k0s-containerd-mirror.sh already adds this; re-adding is a no-op
# if it's there. The Python edit below does nothing if the imports line
# already exists and references our directory.

if [ ! -e "${CONTAINERD_CONFIG}" ]; then
  echo "  ${CONTAINERD_CONFIG} not found — k0s may not have written it yet." >&2
  echo "  Start k0s once (sudo systemctl start k0scontroller) so it generates" >&2
  echo "  the file, then re-run this script." >&2
  exit 1
fi

echo "==> ensuring imports line in ${CONTAINERD_CONFIG}"
backup "${CONTAINERD_CONFIG}"
python3 - "${CONTAINERD_CONFIG}" "${CONTAINERD_IMPORT_DIR}" <<'PY'
import re, sys
path, import_dir = sys.argv[1], sys.argv[2]
content = open(path).read()
glob_path = f"{import_dir}/*.toml"
import_line = f'imports = ["{glob_path}"]'

top_level, sep, rest = content.partition('\n[')

if re.search(r'^imports\s*=', top_level, flags=re.M):
    m = re.search(r'^imports\s*=\s*(\[[^\]]*\])', top_level, flags=re.M)
    if m and glob_path not in m.group(1):
        new_list = m.group(1).rstrip(']').rstrip() + f', "{glob_path}"]'
        top_level = top_level[:m.start(1)] + new_list + top_level[m.end(1):]
        open(path, 'w').write(top_level + (sep + rest if sep else ''))
        print(f"  appended {glob_path} to existing imports list")
    else:
        print("  imports line already includes our glob — no change")
    sys.exit(0)

new_top = top_level.rstrip() + '\n' + import_line + '\n'
open(path, 'w').write(new_top + (sep + rest if sep else ''))
print(f"  inserted: {import_line}")
PY

# --- 3. Restart k0s ---------------------------------------------------------

echo "==> restarting k0s"
restarted=0
for unit in k0scontroller k0sworker; do
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
    systemctl restart "$unit"
    echo "  ${unit} restarted"
    restarted=1
  fi
done
if [ "$restarted" = 0 ]; then
  echo "  no k0s systemd unit found; restart k0s manually so the runtime takes effect." >&2
fi

echo
echo "==> done."
echo "Next steps:"
echo "  1. Wait ~30s for k0s to come back up."
echo "  2. Apply the RuntimeClass + updated positronic-control:"
echo "     k0s kubectl apply -k manifests/stacks/core/"
echo "  3. APPLY=1 bash scripts/diagnose-positronic.sh"
echo
echo "If a pod still says 'NVIDIA Driver was not detected', check:"
echo "  - sudo k0s kubectl get runtimeclass nvidia"
echo "  - the pod's spec.runtimeClassName: nvidia"
echo "  - sudo journalctl -u k0scontroller | grep nvidia"
