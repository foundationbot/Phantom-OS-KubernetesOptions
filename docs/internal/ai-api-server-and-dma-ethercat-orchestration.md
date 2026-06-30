# AI-API-server consolidation + dma-ethercat orchestration & logs

> Status: **design / plan** (for review before implementing). Spans three
> repos: `Phantom-OS-KubernetesOptions`, `ai-api-server`, `argus.operator-ui`.

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

## Open decisions
- Part 1 payload: **deb-baked vs image-extract** (recommend image-extract).
- Per-robot env source in host-config (new `aiApiServer:` block?).
- Confirm the polkit/sudoers scope `install.sh` sets for `phantom-api`
  (must cover `dma-ethercat.service`).
