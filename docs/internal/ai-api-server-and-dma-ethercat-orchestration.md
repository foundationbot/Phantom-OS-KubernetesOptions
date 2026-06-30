# AI-API-server consolidation + dma-ethercat orchestration & logs

> Status: **IMPLEMENTED + deployed on mk11000021 (2026-06-30).** Spans three
> repos: `Phantom-OS-KubernetesOptions`, `ai-api-server`, `argus.operator-ui`.
> See the **As-built** and **Operational gotchas** sections at the bottom for
> what actually shipped and the surprises hit during deploy.

## Why

Two goals:
1. Operator-UI **orchestration tab** should start/stop/restart the host
   `dma-ethercat` systemd service.
2. Operator-UI should show **dma-ethercat logs from Loki**.

Investigating surfaced a deployment split that has to be fixed first.

## Background: the api-server split (resolved)

The robot control API (`phantom_control_api_simple.py`, FastAPI, `:5000`)
had **two** deployments in the fleet:

| Model | Where | Reality |
|---|---|---|
| **Host process** | `/opt/phantom-control-api` + `phantom-control-api.service`, installed by `ai-api-server/scripts/ubuntu/install.sh` | What **mk11test** runs; what argus **nginx** `/api/control/` + `/api/ai/` proxy to (`AI_PC_HOST:5000`). Runs as `phantom-api` user. |
| **k0s pod** | `manifests/base/phantomos-api-server` (DaemonSet, **privileged + hostPID**) | Redundant; nginx never pointed at it. Only ran on mk21 because the manifest deployed it while the host install was skipped. |

**Decision:** standardize fleet-wide on the **host process**; remove the
pod. The host process is what nginx + mk11test already use, and it's more
locked-down (scoped `phantom-api` user vs a privileged hostPID pod).

**Done already:**
- Live privileged DaemonSet deleted on mk21.
- `manifests/base/phantomos-api-server/` removed; `phantom` Namespace
  relocated to `manifests/base/phantom-namespace/`; `stacks/core` updated.
  (`kubectl kustomize stacks/core` verified.)

The remaining root cause: the host install is a **manual per-robot step**
not in the deb/bootstrap — which is exactly why mk21 had no api-server.

---

## Part 1 — Package the host ai-api-server into the deb/bootstrap

**Goal:** every robot auto-installs `/opt/phantom-control-api` +
`phantom-control-api.service` (so none is missed, like mk21 was).

Mirror the existing `install-gaia-host-services.sh` pattern.

1. **Ship the app payload.** Decide how the code reaches the robot:
   - **(a) bake into the deb** under `host-services/phantom-control-api/`
     (like `host-services/gaia/`), or
   - **(b) extract from an image at bootstrap** (like dma-ethercat's
     installer Job) — pull `foundationbot/phantomos-api-server:<tag>`,
     `docker cp` the `/app` out, into `/opt/phantom-control-api`.
   *Recommendation:* (b) — keeps the (large, venv) payload out of the
   `Architecture: all` deb and reuses the existing image build.
2. **Installer script** `scripts/install-phantom-control-api.sh`
   (idempotent): create `phantom-api` user, lay down `/opt/phantom-control-api`
   (venv + src), render `phantom-control-api.service` (from
   `ai-api-server/scripts/ubuntu/phantom-control-api.service`), install the
   **polkit/sudoers** rule that lets `phantom-api` `systemctl` the allowed
   units (incl. `dma-ethercat`), `systemctl enable --now`.
3. **Per-robot env from host-config.** The unit hardcodes
   `PHANTOM_CONTROLLER_JSON_FILE=phantom-0001.json`,
   `PHANTOM_CONTROLLER_INTERFACE=ecat1`, `SERVICE_NAME=...`. Drive these
   from `/etc/phantomos/host-config.yaml` (new `aiApiServer:` block, or
   reuse `dmaEthercat`/`cpuIsolation.nic.iface`).
4. **Wire into bootstrap** as a host phase (next to gaia-host-services),
   opt-out via a host-config flag. nginx already proxies to host:5000 — no
   nginx change.

Open decision: **(a) deb-baked vs (b) image-extract** for the payload.

---

## Part 2 — dma-ethercat control from the orchestration tab

The api-server already has a **`/service` registry** (`/service/status`,
`/service/start`, `/service/stop`) that maps friendly names → systemd units
and controls the **host** systemd (e.g. `positronic_control →
phantom-positronic-control.service`). It does **not** yet know
`dma-ethercat`.

**ai-api-server** (`src/service_manager.py` / `phantom_control_api_simple.py`):
- Add `dma-ethercat` to the service registry / `validate_service_name` +
  `map_to_systemd_name` so `/service/{status,start,stop}` accept
  `service=dma-ethercat` (→ unit `dma-ethercat.service`). Optionally also
  the bridges. *Reuses existing endpoints — no new routes needed* (simpler
  than the dedicated `/ethercat/*` the explore agent sketched).
- Rebuild + bump `phantomos-api-server` image tag; Part 1's installer pulls
  the new tag.

**argus.operator-ui** (`OrchestrationCenter.tsx` + `api/policyApi.ts`):
- Add `getServiceStatus/startService/stopService('dma-ethercat')` calling
  `AI_PC_URL` → nginx `/api/control/service/...` → host:5000.
- Add a "EtherCAT (dma-ethercat)" card mirroring the Phantom Orchestrator
  card (status chip + Start/Stop/Restart).
- Rebuild `argus.operator-ui:gaia-chat`.

⚠️ `systemctl restart dma-ethercat` re-cycles motors to OP (no motion
without a policy + operator enable) — safe, but the card should confirm.

---

## Part 3 — dma-ethercat logs via Loki in operator-ui

**Logs already flow to Loki** (verified on mk21): Vector reads host
journald → OTel → Loki. Labels:
```
service_name = "dma-ethercat.service"   (unit)
service_name = "dma-ethercat.master"    (RT loop)
service_name = "dma-boundary-bridge.service" / "dma-loop-event-bridge.service"
```
**No Vector/Loki change needed.**

operator-ui has **no Loki integration today** (it pulls logs via
ai-api-server `/service/logs` journalctl-SSE). Chosen approach:
**operator-ui → Loki directly.**

1. **Expose Loki to the browser.** It's ClusterIP `gaia:10310` today.
   Add an nginx location (alongside `/api/ai/`) — e.g. `/loki/` →
   `loki.gaia.svc:10310/` — to avoid CORS + browser→ClusterIP exposure.
   (Pure-direct = Loki NodePort + CORS; the nginx proxy is cleaner and
   still "direct from the UI's perspective".)
2. **operator-ui Loki client + panel.** New `api/lokiApi.ts` (LogQL
   `GET /loki/api/v1/query_range`), a dma-ethercat log view querying
   `{service_name=~"dma-ethercat.*|dma-(boundary|loop-event)-bridge.service"}`,
   reusing `LogsDialog.tsx` styling. Add a "Logs" button on the Part 2 card.

---

## Sequencing

1. **(done)** Remove the privileged pod + relocate phantom ns.
2. Part 1 — package host ai-api-server install (unblocks everything).
3. Part 2 — dma-ethercat in `/service` + operator-ui card.
4. Part 3 — Loki panel.
5. Migrate mk11test/mk21 onto the packaged install; rebuild
   `phantomos-api-server` + `argus.operator-ui:gaia-chat` images.

## Open decisions (resolved during implementation)
- Part 1 payload: **deb-baked** (chosen; vendored under
  `host-services/phantom-control-api/app/`). NB the trade-off: the
  `ai-api-server` source is now duplicated — refresh procedure is in that
  dir's `README.md`.
- Per-robot env: unit reads `EnvironmentFile=/etc/phantom-control-api/...env`;
  interface defaults to `ecat1` (the udev-renamed NIC) so no host-config
  wiring was needed.
- polkit: `install.sh` set **no** polkit/sudoers — the installer now ships a
  scoped polkit rule (see below).

---

# As-built (deployed on mk11000021, 2026-06-30)

## What shipped, per repo
- **`Phantom-OS-KubernetesOptions`** (branch `docs/online-install-runbook`, PR #123):
  - `host-services/phantom-control-api/` — vendored app payload + systemd unit
    (`User=phantom-api`, `EnvironmentFile`) + `49-phantom-control-api.rules`
    (scoped polkit JS rule) + README.
  - `scripts/install-phantom-control-api.sh` — idempotent installer (user,
    venv, payload, per-host env, **both** polkit formats, enable+restart).
  - `scripts/bootstrap-robot.sh` — new `phantom-control-api` phase
    (`--phantom-control-api` / `--skip-phantom-control-api`).
  - `manifests/base/gaia/{vector,shm-stats}.yaml` — pinned to `:beta`.
  - `scripts/cpusets/manage_cpusets.sh` + `bootstrap-robot.sh` — `nohz_full`
    fix (see RT section).
- **`ai-api-server`** (branch `feat/dma-ethercat-service-registry`):
  - `dma-ethercat` + `dma-boundary-bridge` + `dma-loop-event-bridge` added to
    `VALID_SERVICES` (category **`AI`** = systemctl, *not* `ROBOT` =
    supervisorctl) + `service_name_map`.
  - `GET /service/status?service_name=` (single-service status).
  - `GET /service/loki-logs` — Loki-backed logs (queries `LOKI_URL`, default
    `http://localhost:10310`; aggregates unit + `.master` + spine bridges).
- **`argus.operator-ui`** (branch `gaia-chat`):
  - `policyApi.ts` — `getHostServiceStatus/startHostService/stopHostService/
    getHostServiceLogs/getHostServiceLokiLogs` (renamed `*HostService` to dodge
    a name clash with `ccServiceApi`).
  - `OrchestrationCenter.tsx` — "EtherCAT Motor Master" card (Start/Restart/Stop
    via `AI_PC_URL` → `:5000`, status chip).
  - `ServiceLogsDialog.tsx` — logs viewer; **prefers Loki**, falls back to
    journalctl, shows the source.

## Service-control model (how the card reaches the robot)
operator-ui calls `appConfig.AI_PC_URL` (= `robot:5000`) **directly** — *not*
through nginx (`/api/` proxies to argus-gateway; service control does not use
it). On mk21 AI PC == robot, so `AI_PC_URL` = the robot itself. The app calls
`systemctl` directly (no sudo); over D-Bus that hits **polkit** — hence the
scoped rule below.

## polkit (the non-obvious bit)
`phantom-control-api.service` runs as the unprivileged `phantom-api` with
`NoNewPrivileges=true`. To let it `systemctl start/stop` the registry units we
ship a polkit grant **in both formats** because the backend differs by distro:
- `49-phantom-control-api.rules` (JS, polkit ≥ 0.106) — scoped to the unit
  allow-list. **mk21 / JetPack runs polkit 124 → this is the honored one.**
- `.pkla` fallback (polkit 0.105 / classic Ubuntu) — written by the installer.

Keep the unit allow-list in the `.rules` in sync with `VALID_SERVICES`.

## Logs: two complementary sources
- **dma-ethercat / bridges** (host systemd) → operator-ui card's Loki panel via
  `ai-api-server /service/loki-logs` (also `/service/logs` journalctl fallback —
  needs `phantom-api` in the `systemd-journal` group, which the installer adds).
- **SHM-fabric pods** (producer/streamer/viewer/dma-bridge) → the gaia "SHM bus"
  tab via the gaia ask_server `/logs` (matches by **k8s container name**, so it
  does *not* cover host-systemd services — that's why the two sources coexist).

## RT isolation / nohz_full
`migrate-cmdline --add-rt-flags` historically emitted `isolcpus`/`skew_tick`/
`irqaffinity`/`rcu_nocb_poll` but **never `nohz_full`/`rcu_nocbs`** — even though
the bootstrap already *checked* for `nohz_full=<dmaRtCpu>`. Added a
`--nohz-full <cpus>` option; bootstrap passes `cpuIsolation.dmaRtCpu`. On mk21:
isolated `10-13`, `dmaRtCpu=11` → cmdline now stages `nohz_full=11` +
`rcu_nocbs=10-13`. **Requires a reboot to activate.** The
`ethercat-irq-affinity.service` already moves general IRQs/workqueues/kthreads
off `10-13`; what remains on the isolated cores is intentional (the `ecat1` NIC
IRQ on core 13) or unmovable (per-CPU timer, managed NVMe vectors, IPIs).

## Deb deliverable
`phantomos-k0s-0-1-3-gaiabeta-20260630-all.deb` (build with
`VERSION=... scripts/build-deb.sh`). Contains the deb-packaged ai-api-server +
dma-ethercat `/service` registry + `/service/loki-logs` + nohz_full fix + gaia
`:beta` manifests. **`Architecture: all`** → build on any host, install anywhere.

---

# Operational gotchas (hit during deploy — read before the next robot)

1. **`build-deb.sh` run inside a git worktree commits onto your branch.** It
   `git init`s the staged tree, but run from a checked-out worktree it ended up
   adding `phantomos-k0s <ver>` commits to the branch (and one *deleted* a
   tracked doc). **Build from an isolated copy:** `rsync -a --exclude=.git
   --exclude=dist <worktree>/ <tmp>/ && cd <tmp> && VERSION=... build-deb.sh`.
2. **ArgoCD app git-source drift.** mk21's apps were pinned to
   `github.com/...@main` even though `host-config gitSource: local`. Symptom:
   manifest changes on a feature branch (or in the deb's `/opt`) never reach the
   robot. Fix = re-run the `--gitops` phase → re-points all apps to
   `file:///opt` at the deb's HEAD SHA. **`kustomize.images` overrides apply
   regardless of git source** (that's why a host-config image override flips
   live even when the manifest doesn't).
3. **RFC-0006 fresh-`git-init`-per-deb breaks ArgoCD incremental fetch.** Each
   deb makes a *new* `git init` with unrelated history, so a hard-refresh can't
   fast-forward the cached clone. `--gitops` re-applies the app at the new SHA,
   which is what makes it pick up the new tree.
4. **`:gaia-chat` (and any mutable branch tag) + `imagePullPolicy: IfNotPresent`
   = stale image.** A `rollout restart` reused a cached image. Force a re-pull:
   `k0s ctr -n k8s.io images rm <ref>` then rollout (kubelet re-pulls via the
   imagePullSecret). Verify by grepping the served JS bundle.
5. **hostNetwork + RollingUpdate = host-port race.** camera-params (`:8420`,
   hostNetwork) threw `Address already in use` while old+new pods overlapped;
   it self-recovered once the old pod died. (Candidate fix: `strategy: Recreate`
   for hostNetwork host-port deployments.)
6. **gaia ask_server image must actually contain the endpoints.** The "SHM bus"
   tab + gaia logs come from ask_server `/fabric` `/fabric/series` `/logs`. Those
   only existed on `SOF-1167`/`gaia-llm-rag`; a stale `gaia-tools:beta` (and
   `main`) returned 404. Fixed by merging `SOF-1167 → beta` (gaia PR #35) so a
   rebuilt `gaia-tools:beta` carries them, then restarting `gaia-ask-server`
   (its `ExecStartPre` re-pulls `:beta`).
7. **Python venv on Ubuntu 24.04 / py3.12:** `import venv` succeeds but
   `ensurepip` is the real prerequisite (`python3-venv`); and `psutil==5.9.6`
   has no cp312/aarch64 wheel → needs `python3-dev` + `gcc` to build.

# Pre-existing issues surfaced (NOT caused by this work)
Chronic crash-loopers (high restart counts predating the deploy) — separate bugs:
- `phantom/dma-recorder` — `journal-collector` sidecar: `dma_journal_collector`
  binary missing from the image.
- `phantom/yovariable-server` — chronic CrashLoopBackOff.
- `positronic/cpp-robot-state-estimator` — chronic CrashLoopBackOff.

After the `--gitops` re-point, the **operator** app shows `OutOfSync` (Healthy)
on the `mongodb`/`redis`/`postgres` StatefulSets (manifest diff vs the deb tree;
`selfHeal=false` so not auto-applied).

# Deferred
- **Reboot mk21** to activate `nohz_full=11`.
- Optionally `strategy: Recreate` for hostNetwork dma-video deployments.
- Investigate the three pre-existing crash-loopers.
