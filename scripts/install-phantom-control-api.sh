#!/usr/bin/env bash
# Install the host phantom-control-api (robot orchestration / systemd-control API
# on :5000, what argus nginx /api/control/ + /api/ai/ proxy to). Idempotent;
# called by bootstrap-robot.sh (phase: phantom-control-api host service) and also
# runnable standalone. Mirrors install-gaia-host-services.sh.
#
# Payload is vendored under host-services/phantom-control-api/app (baked into the
# deb). This script lays it down at /opt/phantom-control-api, builds the venv,
# installs the systemd unit + scoped polkit rule, and enables the service.
#
# Per-host overrides go in /etc/phantom-control-api/phantom-control-api.env and are
# read by the unit's EnvironmentFile. Values can be supplied via env vars when
# calling this script (PCA_API_PORT, PCA_CONTROLLER_JSON, PCA_CONTROLLER_IFACE,
# PCA_POSITRONIC_SERVICE); sane fleet defaults are used otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SRC="$REPO_ROOT/host-services/phantom-control-api"
INSTALL_DIR="/opt/phantom-control-api"
ENV_DIR="/etc/phantom-control-api"
LOG_DIR="/var/log/phantom-control-api"
SERVICE_USER="phantom-api"
DRY_RUN="${DRY_RUN:-0}"

# Per-host values (override via env; defaults match the unit's inline defaults)
PCA_API_PORT="${PCA_API_PORT:-5000}"
PCA_CONTROLLER_JSON="${PCA_CONTROLLER_JSON:-phantom-0001.json}"
PCA_CONTROLLER_IFACE="${PCA_CONTROLLER_IFACE:-ecat1}"
PCA_POSITRONIC_SERVICE="${PCA_POSITRONIC_SERVICE:-phantom-positronic-control.service}"

log()  { printf '  %s\n' "$*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi; }

if [ ! -d "$SRC/app" ]; then
    echo "ERROR: payload not found at $SRC/app — is the deb tree complete?" >&2
    exit 1
fi

# 1. system deps (python venv toolchain). NB: a bare `import venv` can succeed
#    while venv creation still fails because ensurepip (shipped in the versioned
#    python3.X-venv package) is missing — that's the real prerequisite, so test it.
log "ensuring python venv toolchain"
if ! command -v python3 >/dev/null 2>&1; then
    run "apt-get update -qq"
    run "apt-get install -y python3 python3-venv python3-dev"
fi
if ! python3 -c 'import ensurepip' 2>/dev/null; then
    log "ensurepip missing — installing python3-venv"
    run "apt-get update -qq"
    run "apt-get install -y python3-venv"
fi
# Build deps for source wheels. Some pinned deps (e.g. psutil==5.9.6) have no
# prebuilt aarch64/cp312 wheel and compile from source, needing Python.h + gcc.
if ! dpkg -s python3-dev >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
    log "installing build deps (python3-dev, gcc) for source wheels"
    run "apt-get update -qq"
    run "apt-get install -y python3-dev gcc"
fi

# 2. service user (system, no login). systemd-journal group so the /service/logs
#    journalctl path works (control goes via systemctl+polkit; reading the journal
#    needs group membership).
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "creating system user $SERVICE_USER"
    run "useradd --system --no-create-home --shell /usr/sbin/nologin '$SERVICE_USER'"
fi
run "usermod -aG systemd-journal '$SERVICE_USER'"

# 3. directories
log "creating $INSTALL_DIR, $ENV_DIR, $LOG_DIR"
run "mkdir -p '$INSTALL_DIR' '$ENV_DIR' '$LOG_DIR'"

# 4. lay down app payload (rsync so re-runs are clean)
log "syncing app payload -> $INSTALL_DIR"
run "rsync -a --delete '$SRC/app/src' '$SRC/app/static' '$INSTALL_DIR/'"
run "cp '$SRC/app/requirements.txt' '$INSTALL_DIR/requirements.txt'"

# 5. venv (create once, always refresh deps). Gate on pip — not python —
#    presence so a half-built venv from an earlier failed run is rebuilt.
if [ ! -x "$INSTALL_DIR/venv/bin/pip" ]; then
    log "creating venv"
    run "python3 -m venv --clear '$INSTALL_DIR/venv'"
fi
log "installing python deps (needs network)"
run "'$INSTALL_DIR/venv/bin/python' -m pip install --quiet --upgrade pip"
run "'$INSTALL_DIR/venv/bin/python' -m pip install --quiet -r '$INSTALL_DIR/requirements.txt'"

# 6. ownership / perms
run "chown -R '$SERVICE_USER:$SERVICE_USER' '$INSTALL_DIR' '$LOG_DIR'"

# 7. per-host env file (EnvironmentFile for the unit)
log "writing $ENV_DIR/phantom-control-api.env"
if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would write env (API_PORT=$PCA_API_PORT iface=$PCA_CONTROLLER_IFACE json=$PCA_CONTROLLER_JSON)"
else
    cat > "$ENV_DIR/phantom-control-api.env" <<EOF
# Per-host phantom-control-api overrides. Managed by install-phantom-control-api.sh.
API_PORT=$PCA_API_PORT
PHANTOM_CONTROLLER_JSON_FILE=$PCA_CONTROLLER_JSON
PHANTOM_CONTROLLER_INTERFACE=$PCA_CONTROLLER_IFACE
SERVICE_NAME=$PCA_POSITRONIC_SERVICE
EOF
fi

# 8. polkit grant so the unprivileged phantom-api user can systemctl the
#    registry units. Ship BOTH formats because the backend differs by distro:
#    - JS .rules (polkit >= 0.106): scoped to the unit allow-list. Honored on
#      systemd-polkit (newer JetPack / Ubuntu with polkitd JS engine).
#    - .pkla (polkit 0.105 local-authority, classic Ubuntu): action-wide grant
#      (can't scope per-unit). Ignored where .rules is active, and vice-versa.
log "installing polkit JS rule 49-phantom-control-api.rules"
run "mkdir -p /etc/polkit-1/rules.d"
run "install -m 0644 '$SRC/49-phantom-control-api.rules' /etc/polkit-1/rules.d/49-phantom-control-api.rules"
log "installing polkit .pkla fallback (polkit 0.105 / pkla backend)"
run "mkdir -p /etc/polkit-1/localauthority/50-local.d"
if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would write 49-phantom-control-api.pkla"
else
    cat > /etc/polkit-1/localauthority/50-local.d/49-phantom-control-api.pkla <<'EOF'
[phantom-control-api: manage registry units]
Identity=unix-user:phantom-api
Action=org.freedesktop.systemd1.manage-units;org.freedesktop.systemd1.reload-daemon
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
fi

# 9. systemd unit
log "installing phantom-control-api.service"
run "install -m 0644 '$SRC/phantom-control-api.service' /etc/systemd/system/phantom-control-api.service"
run "systemctl daemon-reload"
run "systemctl enable phantom-control-api.service"
# restart (not just enable --now, which no-ops on an already-running service)
# so a re-install picks up updated app payload / env / unit.
run "systemctl restart phantom-control-api.service"

log "phantom-control-api installed (listening on :$PCA_API_PORT)"
