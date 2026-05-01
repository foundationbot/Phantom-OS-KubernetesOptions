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

# --- 1. Drop-in TOML registering the runtime --------------------------------

echo "==> writing ${CONTAINERD_IMPORT}"
mkdir -p "$(dirname "${CONTAINERD_IMPORT}")"
backup "${CONTAINERD_IMPORT}"
cat > "${CONTAINERD_IMPORT}" <<EOF
# Managed by scripts/configure-k0s-nvidia-runtime.sh
# Registers the nvidia container runtime as a containerd runtime named
# "nvidia". Pods that set runtimeClassName: nvidia will be started via
# this runtime, which bind-mounts host driver libraries + Tegra device
# bits into the container.

version = 2

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false
  # Don't set SystemdCgroup here. k0s's default runc runtime uses
  # cgroupfs; setting this runtime to systemd cgroups creates a
  # mismatch with the kubelet (which provides cgroupfs paths) and
  # the pod fails sandbox creation with "expected cgroupsPath to be
  # of format slice:prefix:name". Inherit the cluster default.
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
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
