#!/usr/bin/env bash
# Run okvis2x in RECORD mode on THIS k0s node — captures the DMA camera + IMU
# /dev/shm queues to a host dir (EuRoC/ASL layout) for offline replay / SLAM dev.
# Same image + entrypoint as okvis2x, but args[0]="record" selects the recorder
# (okvis2x_app_record) instead of dma_live. No GPU, no models.
#
# Run it ON the node (no ssh/scp). Kill the okvis2x SLAM DaemonSet first so the
# two don't contend on /dev/shm + GPU (the script warns if it's still up).
#
#   sudo ./record.sh
#   sudo DURATION=600 OUT_SUBDIR=run2 ./record.sh
#   sudo CAMERAS=0,1 ./record.sh
#   sudo IMU_INDEX=1 ./record.sh                                   # record the 2nd IMU in /raw_imu_actuals
#   sudo IMAGE=okvis2x:colby-record_data-260622.51.0 ./record.sh   # locally-imported image
set -eu

NS="${NS:-positronic}"
NODE="${NODE:-$(hostname)}"
# Published recorder image (recorder is baked into this tag, not :latest). For a
# locally-built+imported image, override IMAGE= and it'll use the cached copy.
IMAGE="${IMAGE:-foundationbot/okvis2x:colby-record_data-260622.51.0}"
OUT_HOST="${OUT_HOST:-/data/okvis-recordings}"   # host dir that persists the recording
OUT_SUBDIR="${OUT_SUBDIR:-$(date +%Y%m%d-%H%M%S)}" # subdir under OUT_HOST; defaults to YYYYMMDD-HHMMSS (node local time)
CAMERAS="${CAMERAS:-1,2}"
DURATION="${DURATION:-300}"                      # seconds; 0 = record until the pod is deleted
IMU_INDEX="${IMU_INDEX:-0}"                       # which IMU in /raw_imu_actuals to record (--imu-index)
POD="okvis2x-record"
K="sudo k0s kubectl"

echo "==> [1/3] preflight"
ls /dev/shm/video_meta_cam* >/dev/null 2>&1 || echo "   WARNING: no /dev/shm/video_meta_cam* on this node (no camera frames)"
[ -e /dev/shm/raw_imu_actuals ]            || echo "   WARNING: no /dev/shm/raw_imu_actuals on this node (no IMU)"
if $K -n "$NS" get pods -l app.kubernetes.io/name=okvis2x --no-headers 2>/dev/null | grep -q .; then
  echo "   WARNING: okvis2x SLAM pods still running — kill them first so they don't contend on /dev/shm + GPU:"
  echo "            $K -n $NS delete pod -l app.kubernetes.io/name=okvis2x"
fi

echo "==> [2/3] launch record pod (image=$IMAGE cameras=$CAMERAS imu-index=$IMU_INDEX duration=${DURATION}s -> ${OUT_HOST}/${OUT_SUBDIR})"
$K -n "$NS" delete pod "$POD" --ignore-not-found
cat <<EOF | $K apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: okvis2x-record
spec:
  restartPolicy: Never
  nodeSelector:
    foundation.bot/robot: "true"
    foundation.bot/has-okvis: "true"
  tolerations:
    - { operator: Exists, effect: NoSchedule }
  hostIPC: true                       # mmap the DMA /dev/shm camera + IMU queues
  imagePullSecrets:
    - name: dockerhub-creds
  terminationGracePeriodSeconds: 30   # recorder flushes CSVs on SIGTERM
  containers:
    - name: record
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      # args[0]=record -> okvis2x_app_record; rest is its argv:
      #   <output-dir> [--cameras 0,1,2] [--duration S] [--lossy] [--jpeg-quality Q]
      args: ["record", "/output/${OUT_SUBDIR}", "--cameras", "${CAMERAS}", "--duration", "${DURATION}", "--imu-index", "${IMU_INDEX}"]
      env:
        - { name: OKVIS_DMA_IMU_SHM,        value: /raw_imu_actuals }
        - { name: OKVIS_SKIP_JETSON_CLOCKS, value: "1" }
      volumeMounts:
        - { name: shm,    mountPath: /dev/shm }
        - { name: output, mountPath: /output }
      resources:
        requests: { cpu: "2", memory: "2Gi" }
        limits:   { cpu: "2", memory: "2Gi" }
      securityContext:
        capabilities: { add: ["IPC_LOCK"] }   # mlock for the POSIX /dev/shm queues
  volumes:
    - { name: shm,    hostPath: { path: /dev/shm, type: Directory } }
    - { name: output, hostPath: { path: ${OUT_HOST}, type: DirectoryOrCreate } }
EOF

echo "==> [3/3] follow / manage:"
echo "   $K -n $NS logs -f pod/${POD}"
echo "   recording lands in ${OUT_HOST}/${OUT_SUBDIR} on ${NODE}"
echo "   stop early / clean up:  $K -n $NS delete pod ${POD}"
