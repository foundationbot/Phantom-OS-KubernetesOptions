#!/usr/bin/env bash
# Deploy okvis2x on THIS k0s node — run it ON the node (no ssh/scp, no ArgoCD,
# no bootstrap). Applies the sibling okvis2x.yaml and labels this node so the
# DaemonSet schedules.
#
#   sudo ./deploy.sh                 # node name = hostname
#   sudo NODE=mk11test ./deploy.sh   # override node name
#   sudo NS=positronic ./deploy.sh   # override namespace
#
# Manual escape hatch — the supported path is host-config + bootstrap-robot.sh
# (rendered via ArgoCD). Use this only for dev boxes you drive by hand.
set -eu   # no 'pipefail' so it also runs under dash/sh, not just bash

HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${MANIFEST:-$HERE/okvis2x.yaml}"
NS="${NS:-positronic}"
NODE="${NODE:-$(hostname)}"
K="sudo k0s kubectl"

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

echo "==> [1/3] preflight"
$K get ns "$NS" >/dev/null 2>&1 \
  || { echo "   creating namespace $NS"; $K create namespace "$NS"; }
$K -n "$NS" get secret dockerhub-creds >/dev/null 2>&1 \
  || echo "   WARNING: secret $NS/dockerhub-creds missing — private image pull will fail (create it first)"
$K get runtimeclass nvidia >/dev/null 2>&1 \
  || echo "   WARNING: runtimeclass 'nvidia' missing — GPU pod won't start (host containerd needs the nvidia runtime)"
ls /dev/shm/video_meta_cam* >/dev/null 2>&1 || echo "   WARNING: no /dev/shm/video_meta_cam* (no camera frames on this node)"
[ -e /dev/shm/raw_imu_actuals ]            || echo "   WARNING: no /dev/shm/raw_imu_actuals (no IMU on this node)"

echo "==> [2/3] apply + label node $NODE"
$K apply -f "$MANIFEST"
$K label node "$NODE" foundation.bot/has-okvis=true foundation.bot/robot=true --overwrite

echo "==> [3/3] pods:"
$K -n "$NS" get pods -l app.kubernetes.io/name=okvis2x -o wide

echo
echo "follow logs:"
echo "  $K -n $NS logs -f ds/okvis2x -c load-models"
echo "  $K -n $NS logs -f ds/okvis2x -c okvis2x"
