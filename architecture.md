# PhantomOS (k0s) — robot deployment architecture

> The on-robot stack: a single-node **k0s** cluster running three workload groups —
> **gaia** (observability), **positronic** (control/teleop + GPU), and **argus**
> (operator UI + backend). Validated end-to-end on **mk11test** (phantom-0011,
> Jetson Thor, Ubuntu 24.04 / arm64) on 2026-06-17.
> Companion docs: `gaia/architecture.md` (the observability design), this repo's
> `README.md` (bootstrap), `packaging/deb/README.md` (the installer .deb).

## Overview

One Jetson runs a single-node k0s controller+worker (`k0s controller --single
--enable-worker`, containerd 2.x). All robot software runs as k0s workloads,
replacing the previous docker-compose stacks. The node is the only node; every
pod is pinned to the housekeeping CPUs (0–9), off the RT-isolated cores (10–13).

| Namespace | What | Networking |
|---|---|---|
| `gaia` | otel-collector, prometheus, tempo, loki, grafana, vector, node/process/tegra exporters, shm-stats, kube-state-metrics (container lifecycle now watched by the collector's `k8sobjects` receiver — k8s lifecycle Events → Loki, no dedicated watcher container) | **hostNetwork** (like `dma-video`) — host ports `103xx` |
| `positronic` | `positronic-phantom` (phantom-cuda, GPU), `dma-bridge` (typed taskspace `:9098`) | hostNetwork + hostIPC, nvidia RuntimeClass |
| `argus` | operator-ui, nginx (same-origin proxy), vr-web, argus-{auth,user,company,gateway}, mongodb, redis | ClusterIP + DNS; NodePort `:30080`; hostPorts `:8004` (operator-ui), `:8010` (vr-web TLS) |

Not in k0s (intentionally): the **AI-API-server** (`/opt/phantom-control-api`,
host process on `:5000`) — left running; argus-nginx proxies `/api/ai` and
`/api/control` to it. The `dma-*-bridge` telemetry bridges run as host docker
(deb systemd units) feeding the gaia collector.

## Networking & host ports

hostNetwork pods bind the host directly (no Service remap), so the gaia ports use
the established `103xx` scheme (off `dma-video`'s `:8889` etc.):

| Port | Service | Notes |
|---|---|---|
| `10317/10318` | gaia otel-collector OTLP gRPC/HTTP | the dma bridges + host OTLP clients target this |
| `10389` | collector Prometheus exporter | (moved off `:8889` to avoid mediamtx) |
| `10390` | prometheus UI/API | |
| `10386` | tempo (Grafana Explore / TraceQL query API) | |
| `10310` | loki | |
| `10300` | grafana | |
| `9100/9256/9300` | node / process / shm-stats exporters | scraped by prometheus on localhost |
| `9098` | `dma-bridge` (typed TaskspaceCommand) | FE wire; single owner (legacy `base/dma-bridge` removed) |
| `8004` | operator-ui | hostPort, matches the operator_ui compose `8004:8004` |
| `8010` | vr-web (TLS) | hostPort; TLS from `/opt/certs/<robot>.<tailnet>.ts.net.{crt,key}` |
| `30080` | argus-nginx | NodePort same-origin entry → operator-ui + `/api/*` |
| `5000` | AI-API-server (host) | NOT k0s — `/opt/phantom-control-api`; nginx `/api/ai` + `/api/control` proxy here |

## GPU / nvidia runtime

positronic-phantom requests `runtimeClassName: nvidia` (RuntimeClass in
`manifests/base/runtime-classes`). The handler is registered in k0s's containerd
via a **package-owned drop-in**: `host-services/containerd/nvidia.toml` →
installed to `/etc/k0s/containerd.d/nvidia.toml` by
`scripts/configure-k0s-nvidia-runtime.sh` (bootstrap's nvidia phase). k0s
auto-imports `*.toml` from `containerd.d` into the running config **as long as
`/etc/k0s/containerd.toml` stays k0s-managed** (first line `# k0s_managed=true`)
— so we never edit `containerd.toml` itself. The drop-in uses the
containerd-2.x CRI path `[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]`
with `BinaryName = /usr/bin/nvidia-container-runtime` (k0s 1.36 / containerd
2.x, config `version = 3`). Verified equivalent to the working config on
mk11test (`nvidia-smi` inside positronic-phantom → NVIDIA Thor). The script
warns if a prior install took `containerd.toml` over (marker gone) — drop-ins
then won't load; `rm /etc/k0s/containerd.toml && systemctl restart k0scontroller`
restores k0s management. (mk11test is in that state and works only because its
block was inlined by hand — fresh robots get the clean drop-in path.)

## CPU isolation

Pods inherit the node's housekeeping cpuset (0–9); the RT cores (10–13) stay
isolated for the EtherCAT/control loop. This is node-level (kubepods cgroup /
`--cpu-isolation` phase), not per-pod `taskset` — matching the other core workloads.

## Images — all pulled, none built on the robot

Every image is `docker pull` of a CI-published `foundationbot/*` (or public
upstream); k0s's containerd pulls them (separate from docker's store). Notable:

- positronic: `foundationbot/phantom-cuda:SOF-1167-arm64` (~22.5 GB) +
  `:dma-bridge-SOF-1167-arm64` (the typed-taskspace bridge — NOT the legacy
  `foundationbot/dma_bridge:main`). The `positronic_control` code is **baked into**
  the image (`docker/phantom/production.Dockerfile` `COPY ./ /src`, per-branch/beta
  build) and **pulled** — the DaemonSet has no `/src` (or `.ihmc`) hostPath, so a
  fresh robot needs no host checkout. (Models are still a host mount, below.)
- operator-ui: `foundationbot/argus.operator-ui:gaia-chat` — this is now the
  **manifest default** (fleet-wide). The `_template` no longer pins operator-ui;
  with auto-images on and no image bundle, configure-host emits no override and
  the manifest's `:gaia-chat` applies. Pin per-host only to run a different build.
- **Models** are NOT an image here — mounted from the host
  `/root/phantom-models-merged` → `/root/models` (the `foundationbot/phantom-models`
  busybox image is deferred; the tag currently on DockerHub is a broken amd64/empty build).
- **voice-server** is scaled to 0 — `foundationbot/argus.voice-server:qa` is
  amd64-only (`exec format error` on arm64).

## Per-host / runtime config (NOT in the manifests)

The deb ships manifests + scripts; these per-host bits are applied at deploy time
(by the bootstrap phases or, on mk11test, imperatively) and are **reverted by a
blind `kubectl apply -k argus`** — re-set them or fold them into host-config:

- `operator-ui-pairing` ConfigMap (`ROBOT`, `AI_PC_HOST`, `CONTROL_PC_HOST`).
- operator-ui env `GAIA_HOST` / `RERUN_HOST` (= robot tailscale IP) and the
  `:gaia-chat` image override.
- `/opt/certs/<robot>.<tailnet>.ts.net.{crt,key}` for vr-web TLS
  (from `argus/operator_ui/certs/`, or `tailscale cert`).
- mongo seed: k0s embeds `mongodb-seed-data` inline, but the live deploy was
  seeded from `argus/operator_ui/seed-data.js` (re-create the CM `--from-file`,
  then re-init mongo — initdb only runs on an empty data dir).
- `dockerhub-creds` (per namespace, from the host docker login) and node labels
  `foundation.bot/has-{gaia,positronic,cameras,...}`.
- The k0s-side containerd nvidia config (above).
- **dma-bridges → k0s collector (the trace/event path).** The `dma-{boundary,loop-event}-bridge`
  systemd units (from the `dma-ethercat` `.deb`) read `EnvironmentFile=/etc/dma/dma-bridges.env`.
  The deb's default is now the k0s collector — `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:10317`
  + `GAIA_NETWORK=host` (host-net, since the gaia collector is a hostNetwork pod on `:10317`).
  ⚠️ **Cutover gotcha:** `/etc/dma/dma-bridges.env` is a dpkg **conffile**, so a rig upgraded
  from the compose era **keeps its old value** (`dma-otel-collector:4317` on the dead
  `gaia_default` network) — the bridges then fail every export (`StatusCode.UNAVAILABLE`) and
  **Tempo + Loki stay empty** with no obvious cause. On a cutover you MUST edit the live
  `/etc/dma/dma-bridges.env` to `localhost:10317` + `host` and
  `systemctl restart dma-boundary-bridge dma-loop-event-bridge`. Verify with
  `curl :10386/api/search` → expect `dma-ethercat.master`.
  ⚠️ **Fresh-install gotcha — bridges ship DISABLED.** The two units have
  `[Install] WantedBy=dma-ethercat.service`, which only takes effect once the unit
  is `enable`d. They ship `disabled` (preset is `enabled` but never applied), and
  **nothing in the `dma-ethercat` postinst or bootstrap phase 12 enables them** — so
  after a clean deploy the bridges never start, **Tempo + Loki show zero otel
  traces / dma event streams** (k8s container logs via vector still appear, masking
  the gap), and `systemctl restart dma-ethercat` will NOT bring them up (PartOf only
  restarts *active* units). Fix:
  `systemctl enable --now dma-boundary-bridge dma-loop-event-bridge` — `enable`
  installs the `WantedBy` symlink so they auto-start with `dma-ethercat` thereafter.
  Verify: `dma-ethercat.master` appears in `curl :10386/api/search` (Tempo) and in
  Loki `service_name` values alongside `dma-{boundary,loop-event}-bridge.service`.
  *Durable fix:* add the `systemctl enable` to bootstrap phase 12 (or the
  `dma-ethercat` deb postinst) so a plain deb install brings otel up.
  ⚠️ **Reinstall gotcha — orphaned nerdctl name-store blocks restart.** The bridges
  run as nerdctl containers in containerd ns `dma`. An `dma-ethercat` uninstall→reinstall
  (with the units' `Restart=always` cycling) can leave dangling name reservations at
  `/var/lib/nerdctl/<addr-hash>/dma/dma-{boundary,loop-event}-bridge` (64-byte name→ID
  files) pointing at dead container IDs. The unit then fatals on start with
  `name-store error … name "dma-boundary-bridge" is already used by ID <x>` **even though
  `nerdctl ps -a` and `ctr -n dma c ls` are empty** — `nerdctl rm` by name or ID just says
  "no such container" and can't clear it. Fix: stop the units, then `rm` the stale name
  files plus the orphan `containers/dma/<id>` and `etchosts/dma/<id>` dirs under the data
  root (`/var/lib/nerdctl/<addr-hash>/`), and start. *Durable fix:* harden the unit's
  `ExecStartPre`/`ExecStopPost` to clear orphaned name reservations.

In-manifest (persists across re-apply): nginx `/api/control` → host `:5000`,
operator-ui `:8004` hostPort, the whole `manifests/base/gaia` stack, and
positronic = `positronic-phantom` + `dma-bridge` (old `positronic-control` and
`base/dma-bridge` removed).

## Deploy procedure (single-node cutover)

**One command on a fresh robot:** `dpkg -i phantomos-k0s_*.deb`. The deb's
postinst installs + starts the `phantomos-firstboot.service` oneshot
(`scripts/firstboot-bringup.sh`), which runs the whole sequence unattended:

1. **host-config** — `configure-host.sh --yes` if `/etc/phantomos/host-config.yaml`
   is absent (robot name from `$(hostname)`, AI PC autodetected from tailscale,
   auto-images on, defaults for the rest). An operator-written config is kept.
2. **remove old builds** — `bootstrap-robot.sh`'s default pre-phases stop running
   docker containers + stop/disable host services (the pre-k0s compose stacks that
   hold the same host ports / `/dev/shm` / `:9098`).
3. **bringup** — k0s (`--deps --cluster`), nvidia runtime, `dockerhub-creds`, node
   labels, CPU isolation, then the gitops phase **offline direct-applies** the local
   stacks: with `gitSource: local` and no embedded `.git`, `kubectl apply -k` of
   `manifests/stacks/{core,operator}` (gaia + positronic + … + argus + nimbus). All
   images pull from Docker Hub — **no ArgoCD, no local registry**. (Without this,
   `gitSource=local` + no `.git` used to fall back to ArgoCD tracking github `main`,
   deploying the stale upstream stack from a `localhost:5443` registry; the
   `argocd-admin`/`image-overrides` phases auto-skip when there's no `argocd` ns.)

Guards: the trigger is the absence of `/etc/phantomos/.bootstrap-done` (written on
success), **not** install-vs-upgrade — so a configured-but-not-yet-bootstrapped box
still comes up, while an already-running cluster is **adopted** (marker written, no
re-bootstrap), so routine deb upgrades never tear down a live cluster. Watch it with
`journalctl -u phantomos-firstboot.service -f`; re-run with
`rm -f /etc/phantomos/.bootstrap-done && systemctl start phantomos-firstboot.service`.

Apply the per-host config above (TLS cert, mongo seed, etc.) and validate: gaia
endpoints, GPU in positronic-phantom, operator-ui on `:8004`/`:30080`. The
nvidia runtime is configured declaratively by the deb-shipped containerd drop-in
(see GPU section), so an unattended bringup now brings up positronic with GPU.

## The deployment .deb

`scripts/build-deb.sh` → `dist/phantomos-k0s-<ver>-<arch>.deb` (~300 KB): ships this
repo tree (manifests + scripts + `host-services/` + this doc) to
`/opt/Phantom-OS-KubernetesOptions`. Pure declarative config — **no container images**
(pulled at runtime), **no compiled binaries**, **no per-host config**. Build + install
are dependency-light:

- **No rsync.** The tree is staged with `tar` (build needs only `dpkg-deb` + `tar`;
  `git` just for the version string). Install is a plain `dpkg -i` — extracts to
  `/opt`, no network, no sync. The deb is the only installation.
- **No embedded `.git` by default.** The RFC-0006 git repo (for ArgoCD
  `gitSource: local`, `file:///opt/.../.git`) is OFF by default since we don't run
  ArgoCD — it was >half the deb. Opt in with `EMBED_GIT=1`. Without it, apply the
  manifests directly (`kubectl apply -k`).
- Also installs the **gaia host services** (the RAG tools + GPU/NVMAP textfile
  collectors that run on the host, outside k0s) via the `gaia-host` bootstrap phase
  / `scripts/install-gaia-host-services.sh`.

The `dma-ethercat` `.deb` (RT control + bridge units) is the only other install;
everything else is a pulled image. See `packaging/deb/README.md`.

## Status / follow-ups

- gaia 11 + positronic 2 + argus 8 pods Running on mk11test (voice-server off).
- **No ArgoCD** — manifests are applied directly (`kubectl apply -k`), so the deb's
  embedded `.git` (gitSource:local) is off by default. The gaia, positronic (pulled
  code, no `/src` hostPath), and gaia host-service trees are now committed.
- DONE: `configure-k0s-nvidia-runtime.sh` is containerd-2.x correct — it installs
  the package-owned drop-in `host-services/containerd/nvidia.toml` (no more
  containerd.toml hand-editing). Validate on the next fresh bringup.
- TODO: fold the per-host argus config into the bootstrap (operator-ui-config /
  host-config); publish a correct arm64 `foundationbot/phantom-models`.
- The gaia OTel collector + Tempo memory limits were raised on mk11test (Tempo
  1Gi→2.5Gi, collector 512Mi→~1.25Gi) to stop a Tempo OOM crash-loop that
  surfaced as OTLP `DEADLINE_EXCEEDED` in producers.
- New **"DMA Motor Diagnostics"** Grafana dashboard (uid `dma-motor-diag`) plots
  the SOF-1216 motor-fault BoundaryEvents from Loki (dashboard JSON ships in
  `manifests/base/gaia/config/grafana/dashboards/json/`).
