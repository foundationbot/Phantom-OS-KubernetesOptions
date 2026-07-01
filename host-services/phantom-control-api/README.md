# phantom-control-api (host service)

The robot control API (`phantom_control_api_simple.py`, FastAPI, port **5000**)
that argus nginx proxies to (`/api/control/`, `/api/ai/` → `AI_PC_HOST:5000`).
It controls **host** systemd units (dma-ethercat, positronic, locomotion, …) and
is the backend for the operator-ui orchestration tab.

This is a **host process**, not a k8s workload (it needs host systemd + D-Bus).
It is installed by `scripts/install-phantom-control-api.sh`, invoked by the
`phantom-control-api` phase in `scripts/bootstrap-robot.sh`. See
`docs/internal/ai-api-server-and-dma-ethercat-orchestration.md`.

## Contents

| Path | Purpose |
|---|---|
| `app/` | **Vendored** application payload (see below) |
| `phantom-control-api.service` | systemd unit (User=phantom-api, EnvironmentFile per-host) |
| `49-phantom-control-api.rules` | scoped polkit JS rule (manage registry units) |

The installer also writes a `.pkla` fallback for polkit 0.105 (classic Ubuntu)
and a per-host `/etc/phantom-control-api/phantom-control-api.env`.

## Vendoring

`app/` is **vendored from the `ai-api-server` repo** (`src/`, `static/`,
`requirements.txt`). We bake it into this deb (decision: deb-baked over
image-extract). When `ai-api-server` changes, refresh with:

```bash
SRC=/path/to/ai-api-server
DST=host-services/phantom-control-api/app
rsync -a --delete --exclude='__pycache__' --exclude='*.pyc' "$SRC/src" "$DST/"
rsync -a --delete --exclude='__pycache__' "$SRC/static" "$DST/"
cp "$SRC/requirements.txt" "$DST/requirements.txt"
```

The service registry that maps friendly names → systemd units lives in
`app/src/service_manager.py` (`VALID_SERVICES`) and
`app/src/phantom_control_api_simple.py` (`service_name_map`). Keep the unit
allow-list in `49-phantom-control-api.rules` in sync with it.
