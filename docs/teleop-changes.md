# Teleop changes so far

Summary of the teleoperation-related changes landed on this branch.
Grouped by the part of the stack they touch. For day-to-day operations
see [operations.md](./operations.md).

## Remaining steps

1. Connect the operator UI to control positronic using k0s commands, not
   docker commands.
2. The Docker section of the operator UI should show k0s pods, not
   docker containers.
3. Connect the VR headset to the robot positronic for ROS2 messages.

## Table of contents

- Work already done:
  1. [Operator UI ↔ API server wiring](#1-operator-ui--api-server-wiring)
  2. [VR teleop stack](#2-vr-teleop-stack)
  3. [Cameras (head/teleop video feed)](#3-cameras-headteleop-video-feed)
  4. [Startup ordering](#4-startup-ordering)
  5. [Host configuration / pairing](#5-host-configuration--pairing)

## 1. Operator UI ↔ API server wiring

The core teleop control path: getting the browser-based operator UI
talking to the API servers.

- **Single nginx ingress for the operator UI** (*Fix to connect Operator
  UI to API server, FPort service*) — reworked `argus-nginx` into a
  templated, browser-facing reverse proxy on one NodePort (`30080`).
  Routes:
  - `/` → `operator-ui:8004`
  - `/api/` → `argus-gateway:9100`
  - `/api/ai/` → AI PC `:5000`
  - `/api/control/` → the robot's `phantomos-api-server:5000`

  A same-origin proxy means no CORS / mixed-content problems, and only
  one firewall hole per robot.

- **Host substitution at pod start** — `__AI_PC_HOST__` /
  `__CONTROL_PC_HOST__` are filled in by a `render-config` init
  container from the per-host `operator-ui-pairing` ConfigMap (created
  by `bootstrap-robot.sh` phase 6).

- **API server reachability** (*Remove host network, Update api-server,
  Fix the end point for Argus*) — adjusted `phantomos-api-server`
  networking/endpoints so the operator UI can reach it through the
  gateway.

- **Policy listing** (*api-server: bind-mount host `/root/models`*) —
  bind-mounted host `/root/models` into the API server so it can
  enumerate policies for the operator.

## 2. VR teleop stack

- **VR web port restored to `8010`** and the Deployment switched to the
  `Recreate` strategy. This avoids two pods fighting over the same
  hardware/port during a rollout.

## 3. Cameras (head/teleop video feed)

- **OAK camera stability** (*bootstrap: udev rule disabling autosuspend,
  plus `scripts/configure-usb-power.sh`*) — stops USB autosuspend from
  dropping the OAK cameras.

- **`dma-video` camera config from host** (*load camera config from
  `/etc/phantom/head_camera.json`*) — externalized camera params out of
  the ConfigMap onto the host file.

- **Camera bootstrap changes** (*Changes for cameras, `operator-ui.yaml`
  tweaks*).

## 4. Startup ordering

- **Start `dma-viewer` after `dma-video`** — a `wait-for-producer` probe
  watches `video_meta_cam*`. The producer must come up before the
  consumer, so the viewer now waits on the video producer before
  starting.

## 5. Host configuration / pairing

- **`configure-host`: prefer Tailscale IP in `aiPcUrl` auto-detect** — so
  the AI PC pairing resolves to the right address for the teleop link.
