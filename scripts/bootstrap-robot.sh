#!/usr/bin/env bash
# bootstrap-robot.sh — bring a fresh machine to a working k0s + ArgoCD
# state for this fleet. Idempotent: re-running on a bootstrapped host
# detects existing config and skips destructive steps.
#
# Usage:
#   sudo bash scripts/bootstrap-robot.sh --robot <name> [flags]
#
# Required (first bringup only):
#   --robot <name>     Robot identifier. Must be DNS-1123 (lowercase
#                      alphanumeric + hyphens, 1..63 chars, bookended
#                      by alphanumeric) — it flows into Argo
#                      Application metadata.name (phantomos-<robot>-core,
#                      phantomos-<robot>-operator, ...). No filesystem
#                      check; operators choose names.
#                      On first bringup the value is persisted to
#                      /etc/phantomos/robot; subsequent runs (and other
#                      scripts like positronic.sh) read that file and
#                      no longer require --robot. The flag still wins
#                      when supplied — pass it again to retarget this
#                      host to a different identity.
#
# Flags:
# Per-phase opt-in flags. With NONE of these on the command line,
# every phase runs (full bootstrap). Pass one or more to switch to
# selected-phases-only mode: only the named phases run, everything
# else is skipped. Selected-phases mode implies -y.
#
#   --deps               apt installs + k0s + terraform binaries
#   --cluster            k0s install + systemd start
#   --host               host containerd / nvidia runtime config
#   --seed-pull-secrets  propagate dockerhub-creds Secret to argus,
#                        dma-video, nimbus namespaces
#   --operator-ui-config render+apply the operator-ui-pairing ConfigMap
#                        (currently holds AI_PC_URL; reserved for any
#                        future per-host operator-ui env)
#   --gitops             terraform apply (argocd Helm) + render+apply
#                        the per-host phantomos-<robot> Application
#   --argocd-admin       install argocd CLI; prompt and set admin
#                        password (default '1984' on empty input)
#   --image-overrides    inject host-config.yaml's images list into
#                        the live Application
#   --deployments        inject host-config.yaml's deployments: patches
#                        per stack (or clear them when absent). The
#                        deprecated alias --dev-mounts behaves the same
#                        way for back-compat.
#   --validate           run scripts/validate-local-registry.sh
#
# Targeted overrides (compose with both modes):
#   --skip-nvidia        force-skip nvidia runtime config
#   --skip-validate      skip the final validate-local-registry.sh run
#
# Other flags:
#   -y, --yes          skip confirmation prompts
#   --dry-run          print what each phase would do, change nothing
#   --keep-going       continue after failures (default: bail at first)
#   --production       set selfHeal: true on the per-host Application
#                      (ArgoCD will auto-revert manual cluster edits).
#                      Overrides host-config.yaml's `production:` field
#                      for this run. Use on production robots.
#   --no-production    set selfHeal: false on the per-host Application
#                      (drift reported but not corrected). Overrides
#                      host-config.yaml. Use on dev / debug machines.
#   --reset            Tear down any pre-existing k0s cluster
#                      (`k0s stop && k0s reset`) and back up
#                      /root/.kube/config and terraform/terraform.tfstate*
#                      to .bak.<timestamp>, THEN EXIT. Run the script
#                      again without --reset to bootstrap a fresh
#                      cluster. Splitting the two passes lets the
#                      operator inspect/pull/edit between purge and
#                      rebuild. Cluster workload state is destroyed;
#                      on-disk hostPath data under /var/lib/k0s-data/,
#                      /var/lib/registry/, and /var/lib/recordings/ is
#                      preserved (k0s reset does not touch those paths).
#   --ai-pc-url <url>  AI PC URL for the operator-ui pairing (e.g.
#                      http://100.124.202.97:5000). Required on FIRST
#                      bringup; on re-runs the value is read from
#                      /etc/phantomos/operator-ui-pairing.yaml. Pass
#                      this flag again to re-pair against a different
#                      AI PC.
#   --host-config <path>
#                      copy the given file to /etc/phantomos/host-config.yaml.
#                      The host-config file is the single per-host
#                      source-of-truth (robot identity, aiPcUrl, image
#                      tag overrides, dev mounts). Bootstrap derives
#                      /etc/phantomos/operator-ui-pairing.yaml and the
#                      live Argo Application's spec.source.kustomize.{images,patches}
#                      from it. If --host-config is omitted but the
#                      file already exists, it's used as-is. If it
#                      doesn't exist either, the script falls back to
#                      individual flags (--robot, --ai-pc-url) and
#                      skips image overrides.
#   --setup-positronic after the cluster is up, push a positronic-control
#                      image and build phantom-models so the pod can start.
#                      Requires --positronic-image <image> (e.g.
#                      foundationbot/phantom-cuda:0.2.44-cu130).
#   --positronic-image <image>
#                      local docker image to push as positronic-control
#                      (used with --setup-positronic).
#   --dockerhub-secret-file <path>
#                      path to a file containing the raw `.dockerconfigjson`
#                      payload (the JSON object with `auths`) for the
#                      foundationbot DockerHub deployment account. Used by
#                      phase 5 to build the `dockerhub-creds` Secret.
#                      Default: ~/.docker/config.json (the file `docker
#                      login` writes). If that file is absent or has no
#                      inline `auths` (credsStore-only), phase 5 falls
#                      back to copying an existing `dockerhub-creds`
#                      Secret from the `phantom` namespace.
#
# Examples:
#   sudo bash scripts/bootstrap-robot.sh                       # full bootstrap
#   sudo bash scripts/bootstrap-robot.sh --argocd-admin        # rotate password
#   sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets   # re-seed creds
#   sudo bash scripts/bootstrap-robot.sh --image-overrides     # push tag changes
#   sudo bash scripts/bootstrap-robot.sh --operator-ui-config --image-overrides
#
#   -h, --help         this help
#
# Phases:
#   1. preflight    OS / arch / kernel / disk / sudo / port collisions
#   2. deps         apt: docker.io, skopeo, python3, curl, jq, git,
#                   pciutils, unzip; k0s binary; terraform binary
#   3. cluster      k0s install controller --single --enable-worker;
#                   systemctl enable --now k0scontroller; wait Ready;
#                   write /root/.kube/config from `k0s kubeconfig admin`
#                   (so kubectl + terraform have a config to read).
#                   Runs BEFORE host config because the host-config scripts
#                   edit /etc/k0s/containerd.toml, which only exists after
#                   k0s has started at least once.
#   4. host config  configure-k0s-containerd-mirror.sh +
#                   configure-k0s-nvidia-runtime.sh (if a GPU is detected
#                   via lspci or /dev/nvidia0). Restarts k0s; waits for
#                   node Ready before returning so later phases don't race.
#   5. seed pull secrets
#                   ensure `dockerhub-creds` (kubernetes.io/dockerconfigjson)
#                   exists in `argus`, `dma-video`, `nimbus` so private
#                   foundationbot/* images can be pulled. Source order:
#                   --dockerhub-secret-file, then ~/.docker/config.json
#                   (default), then existing Secret in the `phantom`
#                   namespace, then no-op if already present in every
#                   target namespace. Creates the namespace if it doesn't
#                   exist yet. Idempotent.
#   5.5 operator-ui-config
#                   create/refresh the operator-ui-pairing ConfigMap in
#                   the `argus` namespace from
#                   /etc/phantomos/operator-ui-pairing.yaml. The base
#                   operator-ui Deployment reads AI_PC_URL via
#                   configMapKeyRef. On first bringup --ai-pc-url is
#                   required; subsequent runs without the flag re-apply
#                   the existing local file. Rolls out operator-ui if
#                   the value changed.
#   6. gitops       cd terraform && terraform init && terraform apply
#                   (installs ArgoCD via the official Helm chart). Then
#                   render the per-host Application CR from
#                   host-config-templates/_template/phantomos-app.yaml.tpl
#                   into /etc/phantomos/phantomos-app.yaml using the
#                   resolved robot identity, repo URL, and
#                   targetRevision (from host-config.yaml, default
#                   'main'), and kubectl-apply it. Migrates away from
#                   any pre-existing root-app + child-app topology
#                   without pruning workload state. The repo carries no
#                   per-robot Application files; that data is per-host.
#   6.5 argocd admin install argocd CLI (latest release) under
#                   /usr/local/bin/argocd and reset the admin password
#                   to "1984" by patching argocd-secret with a bcrypt
#                   hash. Idempotent (always rewrites the hash). Also
#                   removes argocd-initial-admin-secret since it is no
#                   longer authoritative.
#   7. setup-positronic (optional, --setup-positronic)
#                   Push positronic-control image to local registry,
#                   build phantom-models, and redeploy the pod.
#   8. validate     bash scripts/validate-local-registry.sh
#
# Exit code = number of FAILures.

set -u -o pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; }

# ---- arg parsing --------------------------------------------------------

ROBOT=""
YES=0
DRY_RUN=0
KEEP_GOING=0
RESET=0
AI_PC_URL=""
HOST_CONFIG_INPUT=""
SETUP_POSITRONIC=0
POSITRONIC_IMAGE=""
DOCKERHUB_SECRET_FILE=""
# Empty = "no flag passed; fall back to host-config.yaml's production
# field (default false)". Flag values: 0 or 1.
PRODUCTION=""

# Phase enable/disable. With no --<phase> flag(s) on the command line,
# every phase runs (full bootstrap). Pass one or more --<phase> flags
# to switch to selected-phases-only mode: only the named phases run,
# everything else is skipped. The fan-out from SELECTED_PHASES into
# the SKIP_* variables happens after arg parsing.
SKIP_DEPS=0
SKIP_HOST=0
SKIP_CLUSTER=0
SKIP_SEED_PULL_SECRETS=0
SKIP_OPERATOR_UI_CONFIG=0
SKIP_GITOPS=0
SKIP_ARGOCD_ADMIN=0
SKIP_IMAGE_OVERRIDES=0
SKIP_DEV_MOUNTS=0
SKIP_VALIDATE=0
SKIP_NVIDIA=0

# Pre-phase + dma-ethercat skip flags (default-on phases, hence the
# inverted polarity from the per-phase opt-in flags above).
SKIP_DOCKER_STOP=0
SKIP_STOP_SERVICES=0
SKIP_ETHERCAT_UNINSTALL=0
SKIP_INSTALL_DMA_ETHERCAT=0
SELECTED_PHASES=()

# Namespaces that pull `foundationbot/*` images and therefore need the
# dockerhub-creds Secret. Kept in sync with REQUIREMENTS.md and with the
# `imagePullSecrets:` references in manifests/base/{argus,dma-video,nimbus}/.
PULL_SECRET_NAMESPACES=(argus dma-video nimbus phantom)
PULL_SECRET_NAME="dockerhub-creds"

# Host-systemd services to stop + disable before bringing up the cluster.
# Each entry is an ERE substring matched case-insensitively against
# `systemctl list-unit-files --state=enabled` output. Append to extend.
#   - api.*server   — host-systemd copy of phantomos-api-server (replaced by pod)
#   - dma.*ethercat — replaced by phase 7 .deb install
SYSTEM_SERVICE_PATTERNS=(
  'api.*server'
  'dma.*ethercat'
)

while [ $# -gt 0 ]; do
  case "$1" in
    # Per-phase opt-in flags. Setting any of these switches to
    # "selected-phases-only" mode: phases NOT in the selected list
    # are skipped. With no per-phase flag, every phase runs.
    --deps)              SELECTED_PHASES+=(deps); shift ;;
    --cluster)           SELECTED_PHASES+=(cluster); shift ;;
    --host)              SELECTED_PHASES+=(host); shift ;;
    --seed-pull-secrets) SELECTED_PHASES+=(seed-pull-secrets); shift ;;
    --operator-ui-config) SELECTED_PHASES+=(operator-ui-config); shift ;;
    --gitops)            SELECTED_PHASES+=(gitops); shift ;;
    --argocd-admin)      SELECTED_PHASES+=(argocd-admin); shift ;;
    --image-overrides)   SELECTED_PHASES+=(image-overrides); shift ;;
    --deployments|--dev-mounts)
                         SELECTED_PHASES+=(dev-mounts); shift ;;
    --install-dma-ethercat)
                         SELECTED_PHASES+=(install-dma-ethercat); shift ;;
    --validate)          SELECTED_PHASES+=(validate); shift ;;

    # Targeted overrides that compose with both modes.
    --skip-nvidia)       SKIP_NVIDIA=1; shift ;;
    --skip-validate)     SKIP_VALIDATE=1; shift ;;
    --skip-docker-stop)  SKIP_DOCKER_STOP=1; shift ;;
    --skip-stop-services) SKIP_STOP_SERVICES=1; shift ;;
    --skip-ethercat-uninstall)
                         SKIP_ETHERCAT_UNINSTALL=1; shift ;;
    --skip-ethercat-install)
                         SKIP_INSTALL_DMA_ETHERCAT=1; shift ;;

    # Inputs.
    --robot)             ROBOT="${2:-}"; shift 2 ;;
    --ai-pc-url)         AI_PC_URL="${2:-}"; shift 2 ;;
    --host-config)       HOST_CONFIG_INPUT="${2:-}"; shift 2 ;;
    --dockerhub-secret-file)
                         DOCKERHUB_SECRET_FILE="${2:-}"; shift 2 ;;
    --setup-positronic)  SETUP_POSITRONIC=1; shift ;;
    --positronic-image)  POSITRONIC_IMAGE="${2:-}"; shift 2 ;;

    # Behavior modifiers.
    -y|--yes)            YES=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --keep-going)        KEEP_GOING=1; shift ;;
    --reset)             RESET=1; shift ;;
    --production)        PRODUCTION=1; shift ;;
    --no-production)     PRODUCTION=0; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ---- helpers ------------------------------------------------------------

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33m• SKIP\033[0m  %s\n' "$1"; }
info() { printf '  \033[2m·\033[0m %s\n' "$1"; }
note() { printf '  \033[36m→\033[0m %s\n' "$1"; }
phase() { printf '\n\033[1;36m──\033[0m \033[1m%s\033[0m\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }

# Hard-stop helper for the dma-ethercat install path. The realtime stack
# must be healthy before the rest of the gitops-managed pods come up:
# positronic-control / dma-video / nimbus all read EtherCAT shared
# memory via hostIPC, so a half-installed .deb wedges the whole fleet
# below in subtle ways. On any failure here we abort the bootstrap with
# a dedicated banner so the cause isn't buried under noise from
# downstream phases. Bypasses --keep-going semantics intentionally:
# ethercat is non-negotiable.
ethercat_die() {
  printf '\n  \033[31mDMA-ETHERCAT FAILURE\033[0m  %s\n' "$1" >&2
  printf '  bootstrap halted — gitops and downstream pods are NOT applied\n' >&2
  printf '  until the realtime stack is healthy. fix the underlying issue\n' >&2
  printf '  and re-run, or pass --skip-ethercat-install to bypass.\n' >&2
  summary
  exit 1
}

# Bail early on FAIL unless --keep-going is set.
guard() { [ "$FAIL" -gt 0 ] && [ "$KEEP_GOING" = 0 ] && summary && exit "$FAIL"; }

# Ensure /etc/phantomos/host-config.yaml exists and validates before any
# phase reads it. Idempotent and cheap when the file is already there.
# When it's missing and we have a TTY, drive scripts/configure-host.sh
# inline (it's the canonical library for the wizard logic — calling it
# as a subshell here gives bootstrap the same wizard the operator would
# get from running configure-host.sh by hand). Non-TTY callers must
# pre-place the file, pass --host-config, or both.
configure_host_ensure_present() {
  local hc="${HOST_CONFIG_FILE:-/etc/phantomos/host-config.yaml}"
  if [ -r "$hc" ] && python3 "$HOST_CONFIG_HELPER" "$hc" validate >/dev/null 2>&1; then
    return 0
  fi
  # --host-config <path> already copied? If so, validate it now and
  # bail fast on a real schema error.
  if [ -r "$hc" ]; then
    fail "$hc exists but does not validate"
    python3 "$HOST_CONFIG_HELPER" "$hc" validate >&2 || true
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  $hc missing; would invoke configure-host.sh wizard"
    return 0
  fi
  if [ ! -t 0 ] || [ ! -t 2 ]; then
    fail "$hc missing and shell is not interactive"
    info "first bringup needs an interactive shell, OR pass --host-config <path>, OR pre-place $hc"
    return 1
  fi
  phase "first-bringup: configure host (wizard)"
  info "no $hc on disk — invoking scripts/configure-host.sh to write one"
  if bash "$SCRIPT_DIR/configure-host.sh" </dev/tty >/dev/tty 2>&1; then
    pass "host-config.yaml written"
  else
    fail "configure-host.sh did not produce a valid $hc"
    return 1
  fi
}

summary() {
  printf '\n==> summary\n  PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
}

# ---- preconditions ------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || die "cd $REPO_ROOT"

# Pull in the shared robot-identity helper. Provides resolve_robot and
# persist_robot. ROBOT_ID_FILE defaults to /etc/phantomos/robot.
# shellcheck source=scripts/lib/robot-id.sh
. "$SCRIPT_DIR/lib/robot-id.sh"

# host-config.yaml — single per-host source-of-truth. If --host-config
# was passed, copy it to the canonical location so subsequent runs use
# the same file. Then, if the file exists, harvest defaults for fields
# the operator didn't pass explicitly via flags.
HOST_CONFIG_FILE="${HOST_CONFIG_FILE:-/etc/phantomos/host-config.yaml}"
HOST_CONFIG_HELPER="$SCRIPT_DIR/lib/host-config.py"

if [ -n "$HOST_CONFIG_INPUT" ]; then
  if [ ! -r "$HOST_CONFIG_INPUT" ]; then
    die "--host-config: $HOST_CONFIG_INPUT not readable"
  fi
  if [ "$DRY_RUN" = 0 ]; then
    if [ "$(id -u)" -ne 0 ]; then
      die "--host-config requires root (writes $HOST_CONFIG_FILE)"
    fi
    mkdir -p "$(dirname "$HOST_CONFIG_FILE")"
    install -m 0644 "$HOST_CONFIG_INPUT" "$HOST_CONFIG_FILE"
    printf '  installed host-config: %s -> %s\n' "$HOST_CONFIG_INPUT" "$HOST_CONFIG_FILE"
  else
    printf '  DRY-RUN  install -m 0644 %s %s\n' "$HOST_CONFIG_INPUT" "$HOST_CONFIG_FILE"
  fi
fi

# Source for host-config harvest. In dry-run we can't have written the
# canonical /etc/phantomos/host-config.yaml yet, so read straight from
# the input path the operator gave us. Otherwise prefer the canonical
# location.
if [ "$DRY_RUN" = 1 ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
  _hc_source="$HOST_CONFIG_INPUT"
elif [ -r "$HOST_CONFIG_FILE" ]; then
  _hc_source="$HOST_CONFIG_FILE"
else
  _hc_source=""
fi

# If a host-config is available, fill in flag defaults. Explicit
# flags still win.
if [ -n "$_hc_source" ]; then
  if [ -z "${ROBOT:-}" ]; then
    if hc_robot="$(python3 "$HOST_CONFIG_HELPER" "$_hc_source" get robot 2>/dev/null)"; then
      ROBOT="$hc_robot"
    fi
  fi
  if [ -z "$AI_PC_URL" ]; then
    if hc_ai="$(python3 "$HOST_CONFIG_HELPER" "$_hc_source" get aiPcUrl 2>/dev/null)"; then
      AI_PC_URL="$hc_ai"
    fi
  fi
fi
unset _hc_source

# Selected-phases mode. If any --<phase> flag was passed, switch from
# "run everything" to "run only the named phases". Implies -y — the
# operator's intent is explicit, no confirmation prompt needed.
if [ "${#SELECTED_PHASES[@]}" -gt 0 ]; then
  SKIP_DEPS=1
  SKIP_CLUSTER=1
  SKIP_HOST=1
  SKIP_SEED_PULL_SECRETS=1
  SKIP_OPERATOR_UI_CONFIG=1
  SKIP_GITOPS=1
  SKIP_ARGOCD_ADMIN=1
  SKIP_IMAGE_OVERRIDES=1
  SKIP_DEV_MOUNTS=1
  SKIP_VALIDATE=1
  SKIP_INSTALL_DMA_ETHERCAT=1
  for _p in "${SELECTED_PHASES[@]}"; do
    case "$_p" in
      deps)              SKIP_DEPS=0 ;;
      cluster)           SKIP_CLUSTER=0 ;;
      host)              SKIP_HOST=0 ;;
      seed-pull-secrets) SKIP_SEED_PULL_SECRETS=0 ;;
      operator-ui-config) SKIP_OPERATOR_UI_CONFIG=0 ;;
      gitops)            SKIP_GITOPS=0 ;;
      argocd-admin)      SKIP_ARGOCD_ADMIN=0 ;;
      image-overrides)   SKIP_IMAGE_OVERRIDES=0 ;;
      dev-mounts)        SKIP_DEV_MOUNTS=0 ;;
      install-dma-ethercat) SKIP_INSTALL_DMA_ETHERCAT=0 ;;
      validate)          SKIP_VALIDATE=0 ;;
    esac
  done
  unset _p
  YES=1
fi

# --reset is a host-level purge that exits before any robot work.
# Robot identity is needed unless every selected phase is one that
# operates at the cluster level only.
_needs_robot=1
if [ "${#SELECTED_PHASES[@]}" -gt 0 ]; then
  _needs_robot=0
  for _p in "${SELECTED_PHASES[@]}"; do
    case "$_p" in
      deps|seed-pull-secrets|argocd-admin|validate|install-dma-ethercat) ;;
      *) _needs_robot=1; break ;;
    esac
  done
  unset _p
fi
if [ "$RESET" = 0 ] && [ "$_needs_robot" = 1 ]; then
  if ! ROBOT="$(resolve_robot "$ROBOT")"; then
    exit 2
  fi
fi
unset _needs_robot

if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "must run as root (try: sudo bash $0 --robot ${ROBOT:-<name>} ...)"
fi

# kubectl resolution (may not exist yet on a fresh machine; fall back later)
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v k0s >/dev/null 2>&1; then
  KUBECTL=(k0s kubectl)
else
  KUBECTL=()
fi

# ---- pre-phase: stop docker containers (default; --skip-docker-stop) ----

purge_docker() {
  if [ "$SKIP_DOCKER_STOP" = 1 ]; then
    phase "pre-phase: stop docker containers  (skipped — --skip-docker-stop)"
    return
  fi
  phase "pre-phase: stop docker containers"

  if ! command -v docker >/dev/null 2>&1; then
    skip "docker not installed — nothing to stop"
    return
  fi
  if [ "$DRY_RUN" = 0 ] && ! docker info >/dev/null 2>&1; then
    skip "docker daemon not reachable — nothing to stop"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    note "DRY-RUN: docker stop \$(docker ps -q)"
    return
  fi

  local running n
  running=$(docker ps -q 2>/dev/null || true)
  if [ -z "$running" ]; then
    skip "no running containers to stop"
    return
  fi
  n=$(printf '%s\n' "$running" | wc -l | tr -d ' ')
  note "stopping $n running container(s)..."
  if docker stop $running >/dev/null 2>&1; then
    pass "stopped $n container(s)"
  else
    fail "docker stop"
  fi
}

# ---- pre-phase: stop+disable enabled system services -------------------

# Walk `systemctl list-unit-files --state=enabled --type=service` and
# stop + disable anything whose name matches one of the patterns in
# SYSTEM_SERVICE_PATTERNS (defined at the top of this script). Default
# patterns cover host-systemd copies of services the cluster will own
# once the bootstrap finishes:
#   - api.*server   -> brought up as a pod by the gitops phase; the
#                      host copy listening on the same port would block
#                      the Service / collide on dependencies.
#   - dma.*ethercat -> uninstalled by the next pre-phase and reinstalled
#                      fresh from the .deb baked into the foundationbot
#                      image; stopping it here ensures phase 4 (cluster)
#                      never sees the running unit.
# Idempotent: a service already stopped/disabled is a no-op. Failures
# are recorded but do not abort.
stop_existing_services() {
  if [ "$SKIP_STOP_SERVICES" = 1 ]; then
    phase "pre-phase: stop system services  (skipped — --skip-stop-services)"
    return
  fi
  phase "pre-phase: stop system services"

  if ! command -v systemctl >/dev/null 2>&1; then
    skip "systemctl not present — nothing to do"
    return
  fi

  local pattern_re
  pattern_re=$(IFS='|'; printf '%s' "${SYSTEM_SERVICE_PATTERNS[*]}")

  local matches
  matches=$(systemctl list-unit-files --state=enabled --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | grep -iE "($pattern_re)" \
    || true)

  if [ -z "$matches" ]; then
    skip "no enabled services match SYSTEM_SERVICE_PATTERNS — nothing to stop"
    return
  fi

  local count
  count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  note "found $count matching service(s):"
  while IFS= read -r u; do
    [ -n "$u" ] && info "  - $u"
  done <<< "$matches"

  if [ "$DRY_RUN" = 1 ]; then
    note "DRY-RUN: would stop (if active) + disable each"
    return
  fi

  note "stopping + disabling each..."
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    local active
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    if [ "$active" = "active" ]; then
      if systemctl stop "$unit" 2>/dev/null; then
        pass "stopped  $unit"
      else
        fail "stop     $unit"
      fi
    else
      skip "stop     $unit  (state=${active:-unknown}, not active)"
    fi
    if systemctl disable "$unit" 2>/dev/null; then
      pass "disabled $unit"
    else
      fail "disable  $unit"
    fi
  done <<< "$matches"
}

# ---- pre-phase: uninstall dma-ethercat (default; --skip-ethercat-uninstall) ----

# Tear down the dma-ethercat realtime control service so phase 7's
# install lands on a clean slate.
#   1. systemctl stop dma-ethercat.service     (if active)
#   2. systemctl disable dma-ethercat.service  (if enabled)
#   3. /usr/sbin/dma-ethercat-uninstall        (if present)
# Each step is a no-op when already in the desired state.
uninstall_ethercat() {
  if [ "$SKIP_ETHERCAT_UNINSTALL" = 1 ]; then
    phase "pre-phase: uninstall dma-ethercat  (skipped — --skip-ethercat-uninstall)"
    return
  fi
  phase "pre-phase: uninstall dma-ethercat"

  local svc=dma-ethercat.service
  local uninstaller=/usr/sbin/dma-ethercat-uninstall

  if ! command -v systemctl >/dev/null 2>&1; then
    skip "systemctl not present — nothing to do"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    note "DRY-RUN: systemctl stop $svc (if active)"
    note "DRY-RUN: systemctl disable $svc (if enabled)"
    note "DRY-RUN: $uninstaller (if present)"
    return
  fi

  local active
  active=$(systemctl is-active "$svc" 2>/dev/null || true)
  if [ "$active" = "active" ]; then
    if systemctl stop "$svc"; then
      pass "stopped $svc"
    else
      fail "stop $svc"
    fi
  else
    skip "$svc not active (state=${active:-unknown})"
  fi

  local enabled
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)
  if [ "$enabled" = "enabled" ]; then
    if systemctl disable "$svc" 2>/dev/null; then
      pass "disabled $svc"
    else
      fail "disable $svc"
    fi
  else
    skip "$svc not enabled (state=${enabled:-unknown})"
  fi

  if [ -x "$uninstaller" ]; then
    note "running $uninstaller..."
    if "$uninstaller"; then
      pass "$uninstaller"
    else
      fail "$uninstaller"
    fi
  else
    skip "$uninstaller not present — nothing to remove"
  fi
}

# ---- pre-phase: reset (only if --reset) --------------------------------

reset_cluster() {
  [ "$RESET" = 0 ] && return
  phase "reset: tear down pre-existing k0s + back up local state"

  if [ "$YES" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    cat <<'EOF' >&2

WARNING: --reset will destroy the running k0s cluster and all workload state:
  - All Pods/Deployments/StatefulSets/ConfigMaps/Secrets are deleted.
  - ArgoCD is uninstalled.
  - Backups (NOT deletes) are made for:
      /etc/k0s/k0s.yaml            -> .bak.<timestamp>
      /root/.kube/config           -> .bak.<timestamp>
      terraform/terraform.tfstate* -> .bak.<timestamp>

Preserved (k0s reset does NOT touch these):
  - /var/lib/k0s-data/{mongodb,redis,postgres}/  StatefulSet hostPath PVs
  - /var/lib/registry/                            registry hostPath PV
  - /var/lib/recordings/                          dma-video hostPath PV (if used)

EOF
    printf 'Continue? [y/N] '
    read -r reply || true
    [[ "$reply" =~ ^[Yy] ]] || { echo "aborted"; exit 1; }
  fi

  local ts
  ts=$(date +%Y%m%d-%H%M%S)

  # 1. Stop + reset k0s (if installed)
  if command -v k0s >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  k0s stop && k0s reset"
    else
      k0s stop 2>/dev/null || true
      sleep 2
      if k0s reset; then
        pass "k0s reset"
      else
        fail "k0s reset failed"
      fi
    fi
  else
    skip "k0s not installed — nothing to tear down on the k0s side"
  fi

  # 2. Back up /etc/k0s/k0s.yaml. `k0s reset` removes /var/lib/k0s and the
  #    k0scontroller systemd unit but deliberately leaves this config file
  #    behind. The cluster phase's "already installed" check is keyed on
  #    this file, so leaving it in place causes that phase to skip
  #    `k0s install controller` (the step that creates the systemd unit)
  #    and then fail the `systemctl enable --now k0scontroller` that follows.
  if [ -e /etc/k0s/k0s.yaml ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  mv /etc/k0s/k0s.yaml /etc/k0s/k0s.yaml.bak.$ts"
    else
      mv /etc/k0s/k0s.yaml "/etc/k0s/k0s.yaml.bak.$ts"
      pass "/etc/k0s/k0s.yaml -> /etc/k0s/k0s.yaml.bak.$ts"
    fi
  else
    skip "/etc/k0s/k0s.yaml absent — nothing to back up"
  fi

  # 3. Back up the kubeconfig (don't delete; user may want it)
  if [ -e /root/.kube/config ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  mv /root/.kube/config /root/.kube/config.bak.$ts"
    else
      mv /root/.kube/config "/root/.kube/config.bak.$ts"
      pass "/root/.kube/config -> /root/.kube/config.bak.$ts"
    fi
  else
    skip "/root/.kube/config absent — nothing to back up"
  fi

  # 4. Back up terraform state (don't delete; it's the only record of
  #    what helm release / namespace terraform was managing)
  for f in terraform/terraform.tfstate terraform/terraform.tfstate.backup; do
    if [ -e "$REPO_ROOT/$f" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        info "DRY-RUN  mv $REPO_ROOT/$f -> $REPO_ROOT/$f.bak.$ts"
      else
        mv "$REPO_ROOT/$f" "$REPO_ROOT/$f.bak.$ts"
        pass "$f -> $f.bak.$ts"
      fi
    fi
  done

  # 5. Reset cached KUBECTL — k0s is gone, anything we cached at startup
  #    is no longer valid until the cluster phase reinstalls it.
  KUBECTL=()
}

# ---- phase 1: preflight -------------------------------------------------

preflight() {
  phase "phase 1: preflight"

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" = "ubuntu" ]; then
      pass "OS: Ubuntu ${VERSION_ID:-?}"
    else
      fail "OS: ${ID:-unknown} (script expects Ubuntu)"
    fi
  else
    fail "OS: /etc/os-release missing"
  fi

  case "$(uname -m)" in
    x86_64|aarch64) pass "arch: $(uname -m)" ;;
    *)              fail "arch: $(uname -m) (untested)" ;;
  esac

  pass "kernel: $(uname -r)"

  free_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)
  if [ "${free_gb:-0}" -ge 50 ]; then
    pass "disk: ${free_gb}G free on /"
  else
    fail "disk: ${free_gb}G free on / (recommend ≥50G for k0s + images)"
  fi

  # Port checks: if a non-cluster process holds 6443/9443/5443, fail.
  for port in 6443 9443 5443; do
    proc=$(ss -tlnp 2>/dev/null | awk -v port=":$port" '$4 ~ port"$" { print $NF; exit }')
    if [ -z "$proc" ]; then
      pass "port $port: free"
    elif printf '%s' "$proc" | grep -qE 'k0s|kube|registry|containerd|kubelet|registry:2'; then
      skip "port $port: held by $proc (expected on a bootstrapped host)"
    else
      fail "port $port: held by $proc"
    fi
  done
}

# ---- phase 2: deps ------------------------------------------------------

deps() {
  if [ "$SKIP_DEPS" = 1 ]; then phase "phase 2: deps  (skipped)"; return; fi
  phase "phase 2: deps"

  apt_pkgs=(docker.io skopeo python3 curl jq git pciutils unzip)
  to_install=()
  for pkg in "${apt_pkgs[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | awk 'BEGIN{ok=1} /^ii/ {ok=0} END {exit ok}'; then
      skip "$pkg already installed"
    else
      to_install+=("$pkg")
    fi
  done

  if [ "${#to_install[@]}" -gt 0 ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  apt-get install -y ${to_install[*]}"
    elif apt-get update -qq && apt-get install -y "${to_install[@]}" >/dev/null; then
      for p in "${to_install[@]}"; do pass "$p installed"; done
    else
      fail "apt install failed for: ${to_install[*]}"
    fi
  fi

  if command -v k0s >/dev/null 2>&1; then
    skip "k0s already in PATH ($(k0s version 2>/dev/null | head -1))"
  elif [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  curl -sSLf https://get.k0s.sh | sh"
  elif curl -sSLf https://get.k0s.sh | sh >/dev/null 2>&1; then
    pass "k0s installed"
  else
    fail "k0s install failed (curl https://get.k0s.sh | sh)"
  fi

  # terraform — fixed minor version, matched binary by host arch. The
  # terraform/ module's README requires >= 1.10.
  TF_VERSION="${TF_VERSION:-1.10.5}"
  if command -v terraform >/dev/null 2>&1; then
    skip "terraform already in PATH ($(terraform version 2>/dev/null | head -1))"
  else
    case "$(uname -m)" in
      x86_64)  tf_arch=amd64 ;;
      aarch64) tf_arch=arm64 ;;
      *)       fail "no terraform binary for arch $(uname -m)"; tf_arch="" ;;
    esac
    if [ -n "$tf_arch" ]; then
      url="https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${tf_arch}.zip"
      if [ "$DRY_RUN" = 1 ]; then
        info "DRY-RUN  download $url -> /usr/local/bin/terraform"
      elif curl -fsSL "$url" -o /tmp/tf.zip \
           && unzip -oq /tmp/tf.zip -d /usr/local/bin \
           && chmod +x /usr/local/bin/terraform \
           && rm -f /tmp/tf.zip; then
        pass "terraform installed (v$TF_VERSION)"
      else
        fail "terraform install failed ($url)"
      fi
    fi
  fi
}

# ---- phase 4: host config -----------------------------------------------

containerd_mirror_already_configured() {
  local f=/etc/k0s/containerd.d/hosts/docker.io/hosts.toml
  [ -r "$f" ] \
    && grep -q 'host."http://localhost:5443"' "$f" \
    && grep -q 'host."https://registry-1.docker.io"' "$f"
}

nvidia_runtime_already_configured() {
  # configure-k0s-nvidia-runtime.sh writes a runtime drop-in. Detect by
  # looking for any nvidia handler entry in containerd's resolved config.
  command -v k0s >/dev/null 2>&1 \
    && k0s config status 2>/dev/null | grep -qi 'nvidia' \
    || grep -rqs 'runtime_type.*nvidia\|nvidia-container-runtime' /etc/k0s/containerd.d 2>/dev/null
}

host_config() {
  if [ "$SKIP_HOST" = 1 ]; then phase "phase 4: host config  (skipped)"; return; fi
  phase "phase 4: host config"

  if containerd_mirror_already_configured; then
    skip "containerd mirror already configured (hosts.toml has localhost:5443 + upstream)"
  elif [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  bash $REPO_ROOT/scripts/configure-k0s-containerd-mirror.sh"
  elif bash "$REPO_ROOT/scripts/configure-k0s-containerd-mirror.sh"; then
    pass "containerd mirror configured"
  else
    fail "configure-k0s-containerd-mirror.sh"
  fi

  # NVIDIA runtime — autodetect, override-able via --skip-nvidia
  if [ "$SKIP_NVIDIA" = 1 ]; then
    skip "nvidia runtime  (--skip-nvidia)"
  else
    has_nvidia=0
    if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi nvidia; then has_nvidia=1; fi
    [ -e /dev/nvidia0 ] && has_nvidia=1
    if [ "$has_nvidia" = 0 ]; then
      skip "nvidia runtime — no NVIDIA hardware detected"
    elif nvidia_runtime_already_configured; then
      skip "nvidia runtime already configured"
    elif [ ! -x "$REPO_ROOT/scripts/configure-k0s-nvidia-runtime.sh" ]; then
      skip "nvidia runtime — configure script not found at scripts/configure-k0s-nvidia-runtime.sh"
    elif [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  bash $REPO_ROOT/scripts/configure-k0s-nvidia-runtime.sh"
    elif bash "$REPO_ROOT/scripts/configure-k0s-nvidia-runtime.sh"; then
      pass "nvidia runtime configured"
    else
      fail "configure-k0s-nvidia-runtime.sh"
    fi
  fi

  # The configure scripts above restart k0scontroller, which causes a brief
  # NotReady window. Block here until kubectl reports Ready again so the
  # next phases (seed_pull_secrets, gitops) don't race the restart.
  if [ "$DRY_RUN" = 0 ] && [ "${#KUBECTL[@]}" -gt 0 ]; then
    info "waiting for node Ready after host config..."
    for _ in $(seq 1 60); do
      if "${KUBECTL[@]}" get nodes 2>/dev/null | awk '/Ready/{ok=1} END{exit !ok}'; then
        info "node Ready"
        return
      fi
      sleep 5
    done
    fail "node did not return to Ready within 5min after host config restart"
  fi
}

# ---- phase 3: cluster ---------------------------------------------------

cluster() {
  if [ "$SKIP_CLUSTER" = 1 ]; then phase "phase 3: cluster  (skipped)"; return; fi
  phase "phase 3: cluster"

  local already_running=0
  systemctl is-active --quiet k0scontroller && already_running=1
  systemctl is-active --quiet k0sworker     && already_running=1

  if [ "$already_running" = 1 ]; then
    skip "k0s already running ($(systemctl is-active k0scontroller k0sworker 2>/dev/null | tr '\n' ' '))"
  elif [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  k0s install controller --single --enable-worker  (if /etc/k0s/k0s.yaml absent)"
    info "DRY-RUN  systemctl enable --now k0scontroller"
  else
    if [ ! -e /etc/k0s/k0s.yaml ]; then
      if k0s install controller --single --enable-worker; then
        pass "k0s installed"
      else
        fail "k0s install"; return
      fi
    else
      skip "k0s already installed (/etc/k0s/k0s.yaml present)"
    fi
    if systemctl enable --now k0scontroller; then
      pass "k0scontroller started"
    else
      fail "systemctl start k0scontroller"; return
    fi
  fi

  # Resolve KUBECTL now that k0s should be installed
  if [ "${#KUBECTL[@]}" -eq 0 ] && command -v k0s >/dev/null 2>&1; then
    KUBECTL=(k0s kubectl)
  fi
  if [ "${#KUBECTL[@]}" -eq 0 ]; then
    [ "$DRY_RUN" = 1 ] && { info "DRY-RUN  wait for node Ready"; return; }
    fail "no kubectl/k0s available to verify node Ready"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  wait for node Ready"
  else
    for _ in $(seq 1 60); do
      if "${KUBECTL[@]}" get nodes 2>/dev/null | awk '/Ready/{ok=1} END{exit !ok}'; then
        pass "node Ready"
        break
      fi
      sleep 5
    done
  fi

  # Write a kubeconfig for root so kubectl + terraform have one to read.
  # `k0s kubeconfig admin` regenerates from the cluster CA every time —
  # safe to run repeatedly.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  k0s kubeconfig admin > /root/.kube/config (chmod 600)"
  else
    mkdir -p /root/.kube
    if k0s kubeconfig admin > /root/.kube/config 2>/dev/null && [ -s /root/.kube/config ]; then
      chmod 600 /root/.kube/config
      pass "/root/.kube/config written ($(wc -c </root/.kube/config) bytes)"
    else
      fail "k0s kubeconfig admin failed"
    fi
  fi
}

# ---- phase 5: seed pull secrets ----------------------------------------

# Build a `dockerhub-creds` Secret (kubernetes.io/dockerconfigjson) and
# apply it to every namespace in PULL_SECRET_NAMESPACES so private
# foundationbot/* image pulls succeed. Fully idempotent — safe to call on
# a fresh cluster, after a rotated PAT, or to recover an existing cluster
# whose pods are stuck in ImagePullBackOff because the secret was missing.
#
# Source resolution order:
#   1. --dockerhub-secret-file <path>      explicit override
#   2. ~/.docker/config.json                default (the file `docker login`
#                                           writes); skipped if it has no
#                                           inline `auths` section, e.g.
#                                           when a credsStore is in use.
#   3. existing Secret in `phantom` ns      cluster-internal fallback (the
#                                           operator pre-created it there
#                                           but didn't propagate to the
#                                           workload namespaces).
#   4. already present in every target ns   no-op skip.
#   5. otherwise                            FAIL with remediation hint.
seed_pull_secrets() {
  if [ "$SKIP_SEED_PULL_SECRETS" = 1 ]; then phase "phase 5: seed pull secrets  (skipped)"; return; fi
  phase "phase 5: seed pull secrets"

  # Resolve KUBECTL — needed when invoked standalone via
  # --seed-pull-secrets on a host where /usr/local/bin/kubectl was
  # never installed (k0s ships its own).
  if [ "${#KUBECTL[@]}" -eq 0 ]; then
    if command -v kubectl >/dev/null 2>&1; then
      KUBECTL=(kubectl)
    elif command -v k0s >/dev/null 2>&1; then
      KUBECTL=(k0s kubectl)
    else
      fail "neither kubectl nor k0s on PATH — cannot seed pull secrets"
      return
    fi
  fi

  # Pick a source file (explicit override, then ~/.docker/config.json).
  local secret_file=""
  if [ -n "$DOCKERHUB_SECRET_FILE" ]; then
    if [ ! -r "$DOCKERHUB_SECRET_FILE" ]; then
      fail "--dockerhub-secret-file $DOCKERHUB_SECRET_FILE: not readable"
      return
    fi
    secret_file="$DOCKERHUB_SECRET_FILE"
    info "source: $secret_file (--dockerhub-secret-file)"
  elif [ -r "$HOME/.docker/config.json" ]; then
    # credsStore-backed configs have no inline auths, so the resulting
    # Secret would authenticate to nothing. Detect that and fall through.
    if jq -e '(.auths // {}) | length > 0' "$HOME/.docker/config.json" >/dev/null 2>&1; then
      secret_file="$HOME/.docker/config.json"
      info "source: $secret_file (default)"
    else
      info "$HOME/.docker/config.json has no inline auths (credsStore?); falling back to phantom ns"
    fi
  fi

  # Build the secret YAML from whichever source resolved.
  local secret_yaml=""
  if [ -n "$secret_file" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  build $PULL_SECRET_NAME from $secret_file"
    else
      secret_yaml=$("${KUBECTL[@]}" create secret generic "$PULL_SECRET_NAME" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=".dockerconfigjson=$secret_file" \
        --dry-run=client -o yaml 2>/dev/null) || {
          fail "kubectl create secret --dry-run failed (is $secret_file valid dockerconfigjson?)"
          return
        }
    fi
  elif "${KUBECTL[@]}" -n phantom get secret "$PULL_SECRET_NAME" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  copy $PULL_SECRET_NAME from phantom namespace"
    else
      secret_yaml=$("${KUBECTL[@]}" -n phantom get secret "$PULL_SECRET_NAME" -o json \
        | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.namespace, .metadata.labels)') || {
          fail "could not read $PULL_SECRET_NAME from phantom ns"
          return
        }
      info "source: phantom/$PULL_SECRET_NAME"
    fi
  else
    # No source. If the secret is already in every target namespace this
    # phase is a clean no-op — the most common case on a re-run.
    local missing=()
    for ns in "${PULL_SECRET_NAMESPACES[@]}"; do
      "${KUBECTL[@]}" -n "$ns" get secret "$PULL_SECRET_NAME" >/dev/null 2>&1 || missing+=("$ns")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
      skip "$PULL_SECRET_NAME already present in: ${PULL_SECRET_NAMESPACES[*]}"
      return
    fi
    fail "$PULL_SECRET_NAME missing in: ${missing[*]}; provide --dockerhub-secret-file <path>, run \`docker login\` so ~/.docker/config.json is populated, or pre-create the Secret in the phantom namespace"
    return
  fi

  # Apply to each target namespace, creating the namespace first if it
  # doesn't exist yet (gitops/argocd may not have created it on first run).
  for ns in "${PULL_SECRET_NAMESPACES[@]}"; do
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  ensure ns/$ns; apply $PULL_SECRET_NAME"
      continue
    fi

    if ! "${KUBECTL[@]}" get ns "$ns" >/dev/null 2>&1; then
      if "${KUBECTL[@]}" create ns "$ns" >/dev/null; then
        info "created ns/$ns"
      else
        fail "could not create ns/$ns"
        continue
      fi
    fi

    if printf '%s' "$secret_yaml" | "${KUBECTL[@]}" apply -n "$ns" -f - >/dev/null; then
      pass "$PULL_SECRET_NAME -> $ns"
    else
      fail "$PULL_SECRET_NAME apply to $ns failed"
    fi
  done
}

# ---- phase 6: operator-ui-config (AI_PC_URL ConfigMap) ---------------

# Per-host pairing file. Holds a ConfigMap manifest that the operator-ui
# Deployment in the argus namespace reads via configMapKeyRef. Lives on
# the host (not in git) so per-robot AI PC URLs don't pollute the GitOps
# tree. --reset preserves it.
PAIRING_FILE="${PAIRING_FILE:-/etc/phantomos/operator-ui-pairing.yaml}"
PAIRING_NS="argus"
PAIRING_CM_NAME="operator-ui-pairing"

# Render the ConfigMap manifest for a given AI PC URL into PAIRING_FILE.
# Caller is responsible for being root.
_write_pairing_file() {
  local url="${1:?_write_pairing_file: url required}"
  mkdir -p "$(dirname "$PAIRING_FILE")"
  cat > "$PAIRING_FILE" <<EOF
# Generated by scripts/bootstrap-robot.sh — do not hand-edit.
# Re-run bootstrap with --ai-pc-url to change the value.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $PAIRING_CM_NAME
  namespace: $PAIRING_NS
data:
  AI_PC_URL: $url
EOF
  chmod 0644 "$PAIRING_FILE"
}

operator_ui_config() {
  if [ "$SKIP_OPERATOR_UI_CONFIG" = 1 ]; then phase "phase 6: operator-ui-config  (skipped)"; return; fi
  phase "phase 6: operator-ui-config (operator-ui AI_PC_URL ConfigMap)"

  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$AI_PC_URL" ]; then
      info "DRY-RUN  write $PAIRING_FILE with AI_PC_URL=$AI_PC_URL"
      info "DRY-RUN  kubectl apply -f $PAIRING_FILE"
    elif [ -r "$PAIRING_FILE" ]; then
      info "DRY-RUN  re-apply existing $PAIRING_FILE"
    else
      info "DRY-RUN  would FAIL: no --ai-pc-url and no $PAIRING_FILE on disk"
    fi
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot apply pairing ConfigMap"
    return
  fi

  # Ensure the argus namespace exists. seed_pull_secrets normally created
  # it already; create defensively when seed-pull-secrets wasn't selected.
  if ! "${KUBECTL[@]}" get ns "$PAIRING_NS" >/dev/null 2>&1; then
    if ! "${KUBECTL[@]}" create ns "$PAIRING_NS" >/dev/null; then
      fail "could not create ns/$PAIRING_NS"
      return
    fi
    info "created ns/$PAIRING_NS"
  fi

  # Decide source: flag overrides file, file is fallback. If neither is
  # available, this is a first bringup that forgot --ai-pc-url.
  if [ -n "$AI_PC_URL" ]; then
    # Sanity: must look like a URL. Reject empty path / missing scheme.
    case "$AI_PC_URL" in
      http://*|https://*) ;;
      *) fail "--ai-pc-url must start with http:// or https:// (got: $AI_PC_URL)"; return ;;
    esac
    _write_pairing_file "$AI_PC_URL"
    pass "wrote $PAIRING_FILE  AI_PC_URL=$AI_PC_URL"
  elif [ ! -r "$PAIRING_FILE" ]; then
    fail "$PAIRING_FILE missing — first bringup needs --ai-pc-url <url>"
    return
  else
    info "re-applying existing $PAIRING_FILE"
  fi

  if ! "${KUBECTL[@]}" apply -f "$PAIRING_FILE" >/dev/null; then
    fail "kubectl apply -f $PAIRING_FILE"
    return
  fi
  pass "$PAIRING_CM_NAME applied to $PAIRING_NS"

  # If operator-ui is already running, restart it so the new value
  # takes effect. envFrom/configMapKeyRef does NOT auto-roll on CM
  # updates — Kubernetes only resolves the value at pod start.
  if "${KUBECTL[@]}" -n "$PAIRING_NS" get deploy operator-ui >/dev/null 2>&1; then
    if "${KUBECTL[@]}" -n "$PAIRING_NS" rollout restart deploy/operator-ui >/dev/null; then
      pass "rolled out operator-ui to pick up new AI_PC_URL"
    else
      fail "rollout restart deploy/operator-ui"
    fi
  else
    info "deploy/operator-ui not present yet — gitops phase will create it with the new CM in scope"
  fi
}

# ---- phase 7: install dma-ethercat (gates phase 8) -------------------

# Install the dma-ethercat .deb baked into the foundationbot/dma-ethercat
# container image, then enable+start the bare-metal service. Runs strictly
# BEFORE phase 8 (gitops) — the realtime stack must be up before
# positronic-control / dma-video / nimbus pods come up because they read
# EtherCAT shared memory via hostIPC.
#
# Templatized: the image tag comes from host-config.yaml's images: list
# (entry name `foundationbot/dma-ethercat`). The Job manifest template
# at manifests/installers/dma-ethercat/base/job.yaml carries
# `:PLACEHOLDER`; bootstrap sed-substitutes the real tag into a rendered
# copy at /etc/phantomos/dma-ethercat-installer.yaml and kubectl-apply's
# that. No per-robot directories under manifests/installers/ — that
# tree was removed in favor of host-config-driven rendering.
#
# Any failure here calls ethercat_die(): the bootstrap halts with a
# DMA-ETHERCAT FAILURE banner and gitops never runs. Pass
# --skip-ethercat-install to bypass (e.g. operator already installed
# the .deb manually).
DMA_ETHERCAT_TEMPLATE="${DMA_ETHERCAT_TEMPLATE:-$REPO_ROOT/manifests/installers/dma-ethercat/base/job.yaml}"
DMA_ETHERCAT_RENDERED="${DMA_ETHERCAT_RENDERED:-/etc/phantomos/dma-ethercat-installer.yaml}"

install_dma_ethercat() {
  if [ "$SKIP_INSTALL_DMA_ETHERCAT" = 1 ]; then
    phase "phase 7: install dma-ethercat  (skipped — --skip-ethercat-install)"
    return
  fi
  phase "phase 7: install dma-ethercat (gates phase 8)"

  if [ ! -f "$DMA_ETHERCAT_TEMPLATE" ]; then
    fail "$DMA_ETHERCAT_TEMPLATE missing"
    ethercat_die "Job template not found at $DMA_ETHERCAT_TEMPLATE"
  fi

  # Resolve image tag from host-config.yaml's images: list. Pull-source
  # mirrors the image_overrides phase (canonical file or --host-config
  # input in dry-run).
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi
  if [ ! -r "$hc" ]; then
    fail "$HOST_CONFIG_FILE missing — cannot resolve dma-ethercat tag"
    ethercat_die "no host-config.yaml — first bringup needs the wizard or --host-config"
  fi

  local tag
  tag="$(python3 - "$hc" <<'PY' 2>/dev/null
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
for entry in (cfg.get("images") or []):
    if isinstance(entry, dict) and entry.get("name") == "foundationbot/dma-ethercat":
        print(entry.get("newTag", ""))
        break
PY
)"
  if [ -z "$tag" ]; then
    fail "host-config.yaml has no images entry for foundationbot/dma-ethercat"
    ethercat_die "add 'foundationbot/dma-ethercat' to host-config.yaml's images: list (e.g. newTag: main-latest-aarch64) and re-run"
  fi
  pass "resolved dma-ethercat tag: $tag"

  # Render the Job manifest (sed-substitute PLACEHOLDER -> tag).
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  render $DMA_ETHERCAT_TEMPLATE -> $DMA_ETHERCAT_RENDERED  (tag=$tag)"
    info "DRY-RUN  kubectl create ns phantom (if missing)"
    info "DRY-RUN  kubectl -n phantom delete job dma-ethercat-installer --ignore-not-found"
    info "DRY-RUN  kubectl apply -f $DMA_ETHERCAT_RENDERED"
    info "DRY-RUN  kubectl -n phantom wait --for=condition=complete job/dma-ethercat-installer"
    info "DRY-RUN  dpkg -i /var/lib/dma-ethercat-installer/dma-ethercat-*.deb"
    info "DRY-RUN  systemctl enable --now dma-ethercat.service"
    return
  fi

  mkdir -p "$(dirname "$DMA_ETHERCAT_RENDERED")"
  sed -e "s#foundationbot/dma-ethercat:PLACEHOLDER#foundationbot/dma-ethercat:$tag#" \
    "$DMA_ETHERCAT_TEMPLATE" > "$DMA_ETHERCAT_RENDERED"
  chmod 0644 "$DMA_ETHERCAT_RENDERED"
  pass "rendered $DMA_ETHERCAT_RENDERED"

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available"
    ethercat_die "kubectl missing — phase 3 (cluster) should have set this up"
  fi

  # Namespace
  if "${KUBECTL[@]}" get ns phantom >/dev/null 2>&1; then
    skip "ns/phantom already exists"
  else
    note "creating ns/phantom..."
    if "${KUBECTL[@]}" create ns phantom >/dev/null; then
      pass "ns/phantom created"
    else
      fail "could not create ns/phantom"
      ethercat_die "cluster may be unhealthy — could not create ns/phantom"
    fi
  fi

  # Force fresh extract on every run — no race against Argo because the
  # Job is bootstrap-managed (lives outside manifests/stacks/, never
  # reconciled by ArgoCD).
  if "${KUBECTL[@]}" -n phantom get job dma-ethercat-installer >/dev/null 2>&1; then
    note "removing prior installer Job (forces fresh extract)..."
    "${KUBECTL[@]}" -n phantom delete job dma-ethercat-installer --ignore-not-found --wait=true >/dev/null 2>&1 || true
    pass "prior Job removed"
  else
    skip "no prior installer Job to remove"
  fi

  note "applying installer manifest..."
  if "${KUBECTL[@]}" apply -f "$DMA_ETHERCAT_RENDERED" >/dev/null; then
    pass "installer Job applied"
  else
    fail "kubectl apply -f $DMA_ETHERCAT_RENDERED"
    ethercat_die "could not apply installer Job — check rendered manifest at $DMA_ETHERCAT_RENDERED"
  fi

  note "waiting up to 5min for installer Job to reach Complete..."
  if "${KUBECTL[@]}" -n phantom wait --for=condition=complete --timeout=300s job/dma-ethercat-installer >/dev/null 2>&1; then
    pass "installer Job Complete"
  else
    local jstat
    jstat=$("${KUBECTL[@]}" -n phantom get job dma-ethercat-installer -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}' 2>/dev/null || true)
    fail "installer Job did not Complete in 5min (status: ${jstat:-unknown})"
    info "pod logs:"
    "${KUBECTL[@]}" -n phantom logs -l app=dma-ethercat-installer --tail=50 2>&1 | sed 's/^/      /' || true
    ethercat_die "installer Job never reached Complete — likely image pull (check dockerhub-creds in phantom ns) or wrong arch tag in host-config images"
  fi

  # dpkg -i. Glob match: image bakes one .deb per arch — exactly one
  # file should be present after the Job's `cp`.
  local deb
  deb=$(ls -1t /var/lib/dma-ethercat-installer/dma-ethercat-*.deb 2>/dev/null | head -1 || true)
  if [ -z "$deb" ]; then
    fail "no dma-ethercat-*.deb at /var/lib/dma-ethercat-installer/"
    ethercat_die "Job ran but did not write the .deb to the host volume — check the Job's pod logs"
  fi
  note "found .deb on host: $(basename "$deb")"
  note "running dpkg -i..."
  if dpkg -i "$deb"; then
    pass "dpkg -i $(basename "$deb")"
  else
    fail "dpkg -i $deb"
    ethercat_die "dpkg -i failed — check above output for missing dependencies or conflicting packages"
  fi

  # Enable + start. Failed start halts the bootstrap.
  note "enabling + starting dma-ethercat.service..."
  if systemctl enable --now dma-ethercat.service; then
    pass "dma-ethercat.service enabled and started"
  else
    fail "systemctl enable --now dma-ethercat.service"
    info "unit status:"
    systemctl --no-pager status dma-ethercat.service 2>&1 | sed 's/^/      /' || true
    ethercat_die "service did not start — check systemctl status / journalctl -u dma-ethercat for the underlying cause"
  fi
}

# ---- phase 8: gitops ----------------------------------------------------

# Phase 6 has two pieces:
#   6a. terraform install of argocd Helm chart
#   6b. render the per-host Application CR from
#       host-config-templates/_template/phantomos-app.yaml.tpl using
#       robot id + repoURL + targetRevision (from host-config or
#       default 'main'), apply it to the cluster.
#
# The repo carries no per-robot Application files. The Application CR
# is per-host state, generated and applied by this phase. Migration
# from the old root-app + child-app design is handled inline (see
# _gitops_migrate_from_root_app).
APP_TEMPLATE_FILE="${APP_TEMPLATE_FILE:-$REPO_ROOT/host-config-templates/_template/phantomos-app.yaml.tpl}"
# One rendered Application per enabled stack:
#   /etc/phantomos/phantomos-app-core.yaml
#   /etc/phantomos/phantomos-app-operator.yaml
RENDERED_APP_DIR="${RENDERED_APP_DIR:-/etc/phantomos}"
DEFAULT_REPO_URL="${DEFAULT_REPO_URL:-https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git}"
DEFAULT_TARGET_REVISION="${DEFAULT_TARGET_REVISION:-main}"

_rendered_app_path() {
  local stack="${1:?stack required}"
  printf '%s/phantomos-app-%s.yaml' "$RENDERED_APP_DIR" "$stack"
}

# Strip a single Application from the cluster WITHOUT cascade-pruning
# its workloads. Used during migration so the new Application can claim
# the existing resources without taking them down first.
_gitops_orphan_delete_app() {
  local app="${1:?app required}"
  if ! "${KUBECTL[@]}" -n argocd get app "$app" >/dev/null 2>&1; then
    return 0
  fi
  "${KUBECTL[@]}" -n argocd patch app "$app" \
    --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  "${KUBECTL[@]}" -n argocd delete app "$app" --wait=false >/dev/null 2>&1 || true
  info "removed legacy Application: $app"
}

# Two migration steps roll into one helper:
#   1. Old app-of-apps era: a `root` Application + per-robot
#      phantomos-<robot>* children. Drop root + any non-matching
#      phantomos-* without cascade.
#   2. Stage D era: a single umbrella `phantomos-<robot>` (no -<stack>
#      suffix) per cluster. With per-stack Applications, we replace it
#      with phantomos-<robot>-core / phantomos-<robot>-operator.
_gitops_migrate_legacy_apps() {
  local nsdone=0
  if "${KUBECTL[@]}" -n argocd get app root >/dev/null 2>&1; then
    info "found legacy 'root' Application — migrating away from app-of-apps"
    _gitops_orphan_delete_app root
    nsdone=1
  fi

  # The Stage D umbrella: name == "phantomos-<robot>" exactly.
  if "${KUBECTL[@]}" -n argocd get app "phantomos-$ROBOT" >/dev/null 2>&1; then
    info "found umbrella 'phantomos-$ROBOT' Application — migrating to per-stack"
    _gitops_orphan_delete_app "phantomos-$ROBOT"
    nsdone=1
  fi

  # Anything else named phantomos-* that doesn't match this robot's
  # current per-stack naming gets cleaned up too.
  local apps app
  apps=$("${KUBECTL[@]}" -n argocd get app -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    case "$app" in
      phantomos-$ROBOT-core|phantomos-$ROBOT-operator) continue ;;
      phantomos-*)
        _gitops_orphan_delete_app "$app"
        nsdone=1
        ;;
    esac
  done <<< "$apps"

  [ "$nsdone" = 1 ] && pass "legacy Application cleanup complete"
}

# Render the Application CR template into RENDERED_APP_DIR for one
# stack. Substitutions are simple sed because the template values are
# repo-controlled (no shell injection surface from operator input).
_gitops_render_app() {
  local stack="${1:?stack required}"
  local repo_url="${2:?repo_url required}"
  local target_rev="${3:?target_rev required}"
  local self_heal="${4:?self_heal required}"
  local out
  out="$(_rendered_app_path "$stack")"

  if [ ! -r "$APP_TEMPLATE_FILE" ]; then
    fail "Application CR template not found: $APP_TEMPLATE_FILE"
    return 1
  fi

  mkdir -p "$(dirname "$out")"
  sed \
    -e "s#{{ROBOT}}#$ROBOT#g" \
    -e "s#{{STACK}}#$stack#g" \
    -e "s#{{REPO_URL}}#$repo_url#g" \
    -e "s#{{TARGET_REVISION}}#$target_rev#g" \
    -e "s#{{SELF_HEAL}}#$self_heal#g" \
    "$APP_TEMPLATE_FILE" > "$out"
  chmod 0644 "$out"
}

gitops() {
  if [ "$SKIP_GITOPS" = 1 ]; then phase "phase 8: gitops  (skipped)"; return; fi
  phase "phase 8: gitops (install argocd + apply per-host Application)"

  if [ ! -d "$REPO_ROOT/terraform" ]; then
    fail "terraform/ not found at $REPO_ROOT/terraform"; return
  fi

  if ! command -v terraform >/dev/null 2>&1 && [ "$DRY_RUN" = 0 ]; then
    fail "terraform not in PATH — phase 2 should have installed it"; return
  fi

  local kc=/root/.kube/config
  if [ "$DRY_RUN" = 0 ] && [ ! -r "$kc" ]; then
    fail "$kc not readable — phase 3 (cluster) should have written it"; return
  fi

  # Resolve targetRevision: --host-config wins, then explicit override
  # via DEFAULT_TARGET_REVISION env, then 'main'.
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi
  local target_rev="$DEFAULT_TARGET_REVISION"
  if [ -r "$hc" ]; then
    if hc_rev="$(python3 "$HOST_CONFIG_HELPER" "$hc" get targetRevision 2>/dev/null)"; then
      target_rev="$hc_rev"
    fi
  fi

  # Enabled stacks (one per line); per-stack selfHeal (resolved against
  # production: + --production override).
  local enabled_stacks=""
  if [ -r "$hc" ]; then
    enabled_stacks="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-enabled-stacks 2>/dev/null || true)"
  fi
  if [ -z "$enabled_stacks" ]; then
    # No host-config — fall back to the 'all stacks default' (matches
    # cmd_get_enabled_stacks's behavior when stacks: is omitted).
    enabled_stacks=$'core\noperator'
  fi

  # selfHeal resolution per stack: stacks.<name>.selfHeal (when set) >
  # --production CLI flag > production: in host-config > false.
  _resolve_selfheal_for_stack() {
    local stack="$1"
    if [ -r "$hc" ]; then
      if v="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-stack-selfheal "$stack" 2>/dev/null)"; then
        # If host-config has an explicit per-stack value, helper returns it.
        # Otherwise it returns the production: fallback. CLI --production
        # overrides only when the stack didn't set its own.
        local stack_explicit
        stack_explicit="$(python3 - "$hc" "$stack" <<'PY' 2>/dev/null
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
spec = (cfg.get("stacks") or {}).get(sys.argv[2]) or {}
if isinstance(spec, dict) and "selfHeal" in spec:
    print("yes")
PY
)"
        if [ "$stack_explicit" != "yes" ] && [ -n "$PRODUCTION" ]; then
          [ "$PRODUCTION" = 1 ] && printf 'true\n' || printf 'false\n'
          return
        fi
        printf '%s\n' "$v"
        return
      fi
    fi
    [ "$PRODUCTION" = 1 ] && printf 'true\n' || printf 'false\n'
  }

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  cd $REPO_ROOT/terraform && terraform init && terraform apply -auto-approve -var=kubeconfig=$kc"
    info "DRY-RUN  enabled stacks: $(printf '%s' "$enabled_stacks" | tr '\n' ' ')"
    while IFS= read -r stack; do
      [ -z "$stack" ] && continue
      local sh
      sh="$(_resolve_selfheal_for_stack "$stack")"
      info "DRY-RUN    render template for stack=$stack  selfHeal=$sh"
      info "DRY-RUN    kubectl apply -f $(_rendered_app_path "$stack")"
    done <<< "$enabled_stacks"
    info "DRY-RUN  wait for each phantomos-$ROBOT-<stack> Synced + Healthy"
    return
  fi

  # If ArgoCD is already installed (not via this terraform state), warn
  # but proceed — terraform will adopt the existing namespace.
  if "${KUBECTL[@]}" get ns argocd >/dev/null 2>&1 && \
     ! [ -f "$REPO_ROOT/terraform/terraform.tfstate" ]; then
    info "argocd ns exists but no terraform state file — terraform will adopt it"
  fi

  (
    cd "$REPO_ROOT/terraform" || exit 2
    terraform init -input=false -upgrade=false
  ) || { fail "terraform init"; return; }
  pass "terraform init"

  (
    cd "$REPO_ROOT/terraform" || exit 2
    terraform apply -input=false -auto-approve -var="kubeconfig=$kc"
  ) || { fail "terraform apply"; return; }
  pass "terraform apply (argocd Helm install)"

  # Migrate from any pre-existing root-app or umbrella Application.
  _gitops_migrate_legacy_apps

  # Drop Applications for stacks that USED to be enabled but aren't
  # anymore — e.g. operator was true, operator: enabled: false now.
  # Cascade-prune is fine here: the operator workloads SHOULD come down.
  local rendered_stacks=""
  while IFS= read -r stack; do
    [ -z "$stack" ] && continue
    rendered_stacks="${rendered_stacks} $stack"
  done <<< "$enabled_stacks"

  for known_stack in core operator; do
    case " $rendered_stacks " in
      *" $known_stack "*) continue ;;
    esac
    if "${KUBECTL[@]}" -n argocd get app "phantomos-$ROBOT-$known_stack" >/dev/null 2>&1; then
      info "stack $known_stack disabled — removing phantomos-$ROBOT-$known_stack and its workloads"
      "${KUBECTL[@]}" -n argocd delete app "phantomos-$ROBOT-$known_stack" --wait=false >/dev/null 2>&1 \
        || fail "could not delete phantomos-$ROBOT-$known_stack"
      rm -f "$(_rendered_app_path "$known_stack")" 2>/dev/null || true
    fi
  done

  # Render and apply each enabled stack's Application.
  while IFS= read -r stack; do
    [ -z "$stack" ] && continue
    local sh
    sh="$(_resolve_selfheal_for_stack "$stack")"
    if ! _gitops_render_app "$stack" "$DEFAULT_REPO_URL" "$target_rev" "$sh"; then
      return
    fi
    pass "rendered $(_rendered_app_path "$stack")  stack=$stack  branch=$target_rev  selfHeal=$sh"

    if ! "${KUBECTL[@]}" apply -f "$(_rendered_app_path "$stack")" >/dev/null; then
      fail "kubectl apply -f $(_rendered_app_path "$stack")"
      return
    fi
    pass "phantomos-$ROBOT-$stack applied"
    # Force ArgoCD to reconcile immediately instead of waiting for the
    # next 3-min refresh tick.
    "${KUBECTL[@]}" -n argocd annotate app "phantomos-$ROBOT-$stack" \
      argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done <<< "$enabled_stacks"

  # No Synced wait — phases 10 (image-overrides) and 11 (deployments)
  # only need the Application resource to exist (kubectl apply above
  # makes it so), not for ArgoCD to have reconciled yet. Their patches
  # land on the spec; ArgoCD's next reconcile renders with them in
  # place. The validate phase confirms Healthy.
}

# ---- phase 10: kustomize image overrides (per-host, per-stack) ---------

# Each entry in host-config's images: list belongs to exactly one stack.
# Bootstrap discovers the mapping by running kustomize on each enabled
# stack and indexing image references in the rendered output. Then it
# patches each stack's Application with only the images it owns.
#
# The image-to-stack map is computed once and cached for use by both
# image_overrides and dev_mounts (the latter currently only targets
# positronic-control which is hardcoded to `core`, but the same
# mechanism is general-purpose).
_IMAGE_STACK_MAP=""   # newline-separated: "<image>\t<stack>"

_kustomize_cmd() {
  if command -v kustomize >/dev/null 2>&1; then
    printf 'kustomize\n'
  elif command -v kubectl >/dev/null 2>&1 && kubectl kustomize --help >/dev/null 2>&1; then
    printf 'kubectl kustomize\n'
  elif command -v k0s >/dev/null 2>&1; then
    printf 'k0s kubectl kustomize\n'
  else
    printf '\n'
  fi
}

# Build the image -> stack mapping for the given enabled stacks. Cached
# in $_IMAGE_STACK_MAP. Idempotent within a single bootstrap run.
_build_image_stack_map() {
  [ -n "$_IMAGE_STACK_MAP" ] && return 0
  local stacks="${1:?stacks required}"
  local kk
  kk="$(_kustomize_cmd)"
  if [ -z "$kk" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  no kustomize tooling on this host — skipping image-to-stack scan; real run will resolve via 'k0s kubectl kustomize'"
      _IMAGE_STACK_MAP="<dry-run-no-scan>"
      return 1
    fi
    fail "neither kustomize, kubectl, nor k0s available — cannot scan stacks"
    return 1
  fi
  local map=""
  while IFS= read -r stack; do
    [ -z "$stack" ] && continue
    local rendered
    if ! rendered="$($kk "$REPO_ROOT/manifests/stacks/$stack" 2>/dev/null)"; then
      fail "kustomize build failed for manifests/stacks/$stack"
      return 1
    fi
    local images
    images="$(printf '%s' "$rendered" | python3 -c '
import sys, yaml
seen = set()
for doc in yaml.safe_load_all(sys.stdin):
    if not isinstance(doc, dict):
        continue
    pod = (doc.get("spec", {}).get("template", {}).get("spec", {})
           if doc.get("kind") in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
           else doc.get("spec", {}) if doc.get("kind") == "Pod" else {})
    for c in (pod.get("containers", []) or []) + (pod.get("initContainers", []) or []):
        img = c.get("image", "")
        if not img:
            continue
        # Strip tag/digest, keep "name" portion (registry/path/repo).
        if "@" in img:
            img = img.split("@", 1)[0]
        if img.count(":") >= 1 and not img.startswith("localhost:") \
           and ":" in img.rsplit("/", 1)[-1]:
            img = img.rsplit(":", 1)[0]
        elif img.startswith("localhost:") and img.count(":") >= 2:
            img = img.rsplit(":", 1)[0]
        seen.add(img)
for n in sorted(seen):
    print(n)
')"
    while IFS= read -r img; do
      [ -z "$img" ] && continue
      map="$map$img"$'\t'"$stack"$'\n'
    done <<< "$images"
  done <<< "$stacks"
  _IMAGE_STACK_MAP="$map"
  return 0
}

# Echo the stack name that owns the given image reference, or empty
# if no enabled stack contains it. Image refs match by full registry/path
# (e.g. "localhost:5443/positronic-control" or
# "foundationbot/argus.operator-ui").
_stack_for_image() {
  local needle="${1:?image required}"
  while IFS=$'\t' read -r img stack; do
    if [ "$img" = "$needle" ]; then
      printf '%s\n' "$stack"
      return 0
    fi
  done <<< "$_IMAGE_STACK_MAP"
  return 1
}

image_overrides() {
  if [ "$SKIP_IMAGE_OVERRIDES" = 1 ]; then phase "phase 10: image overrides  (skipped)"; return; fi
  phase "phase 10: image overrides (inject kustomize.images per stack)"

  # In dry-run before --host-config has actually been installed, fall
  # back to the input path the operator passed.
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi
  if [ ! -r "$hc" ]; then
    skip "$HOST_CONFIG_FILE missing — no per-host image overrides to inject (overlay defaults apply)"
    return
  fi

  # Get host-config's flat images list. Each item is a string of the
  # form "name:newTag" (or "name=newName:newTag"). We split off the
  # name to look up the stack, then route the entire entry there.
  local images_json
  if ! images_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-images-json 2>&1)"; then
    fail "host-config images parse error: $images_json"
    return
  fi
  if [ "$images_json" = "[]" ]; then
    skip "host-config has no images: block — nothing to inject"
    return
  fi

  # Enabled stacks for this host-config.
  local enabled_stacks
  enabled_stacks="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-enabled-stacks 2>/dev/null || true)"
  if [ -z "$enabled_stacks" ]; then
    enabled_stacks=$'core\noperator'
  fi

  # Build image -> stack map (kustomize-scan; cached). In dry-run on a
  # host without kustomize tooling, the helper soft-fails — show a
  # placeholder routing table and continue.
  if ! _build_image_stack_map "$enabled_stacks"; then
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  (routing table not computed; on a real run each image"
      info "DRY-RUN   would be matched to its owning stack via kustomize scan)"
      printf '%s' "$images_json" | python3 -c '
import json, sys
imgs = json.load(sys.stdin)
print(f"  DRY-RUN  {len(imgs)} image(s) to route across enabled stacks")
'
      return
    fi
    return
  fi

  # Group images by owning stack (Python — easier than nested bash).
  local routing_json
  routing_json="$(python3 - "$_IMAGE_STACK_MAP" "$images_json" <<'PY' 2>&1
import json, sys
mapping_raw, images_json = sys.argv[1], sys.argv[2]
img_to_stack = {}
for line in mapping_raw.splitlines():
    if "\t" in line:
        img, stack = line.split("\t", 1)
        img_to_stack[img] = stack

# Images consumed by bootstrap-managed Jobs (not by any stack). These
# are read directly by their phase (e.g. install_dma_ethercat reads
# foundationbot/dma-ethercat from host-config to render the installer
# Job) and intentionally don't route to a stack's kustomize.images.
# Skip silently rather than warn.
NON_STACK_IMAGES = {
    "foundationbot/dma-ethercat",  # phase 7 install_dma_ethercat
}

per_stack: dict[str, list[str]] = {}
unrouted: list[str] = []
for entry in json.loads(images_json):
    # entry is "name:newTag" or "name=newName:newTag"
    name = entry.split("=", 1)[0] if "=" in entry else entry.rsplit(":", 1)[0]
    if name in NON_STACK_IMAGES:
        continue
    stack = img_to_stack.get(name)
    if stack:
        per_stack.setdefault(stack, []).append(entry)
    else:
        unrouted.append(entry)

print(json.dumps({"per_stack": per_stack, "unrouted": unrouted}))
PY
)"
  if ! printf '%s' "$routing_json" | grep -q '"per_stack"'; then
    fail "image routing failed: $routing_json"
    return
  fi

  # Surface unrouted entries (image not found in any enabled stack).
  local unrouted_count
  unrouted_count="$(printf '%s' "$routing_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["unrouted"]))')"
  if [ "$unrouted_count" -gt 0 ]; then
    info "warning: $unrouted_count image(s) in host-config not found in any enabled stack:"
    printf '%s' "$routing_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for entry in d["unrouted"]:
    print(f"    {entry}")
'
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '%s' "$routing_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for stack, imgs in d["per_stack"].items():
    print(f"  DRY-RUN  patch phantomos-'"$ROBOT"'-{stack} kustomize.images = {imgs}")
'
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch Application"
    return
  fi

  # For each stack that has routed images, patch its Application.
  local stacks_with_overrides
  stacks_with_overrides="$(printf '%s' "$routing_json" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["per_stack"].keys()))')"
  while IFS= read -r stack; do
    [ -z "$stack" ] && continue
    local app="phantomos-$ROBOT-$stack"
    if ! "${KUBECTL[@]}" -n argocd get app "$app" >/dev/null 2>&1; then
      fail "Application $app not present — gitops phase must run first"
      continue
    fi
    local stack_imgs_json
    stack_imgs_json="$(printf '%s' "$routing_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d["per_stack"]["'"$stack"'"]))
')"
    local patch
    patch=$(printf '{"spec":{"source":{"kustomize":{"images":%s}}}}' "$stack_imgs_json")
    if "${KUBECTL[@]}" -n argocd patch app "$app" --type=merge -p "$patch" >/dev/null; then
      pass "patched $app  kustomize.images: $stack_imgs_json"
    else
      fail "kubectl patch app $app failed"
      continue
    fi
    "${KUBECTL[@]}" -n argocd patch app "$app" \
      --type=merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 \
      && pass "triggered sync of $app"
  done <<< "$stacks_with_overrides"
}

# ---- phase 11: dev hostPath mounts (per-host) --------------------------

# Inject strategic-merge patches derived from
# /etc/phantomos/host-config.yaml's `deployments:` block into the live
# Argo Applications. Each deployment under `deployments:` resolves to
# a target Application based on which stack owns it (positronic-control
# -> core; phantomos-api-server -> core). All patches for one stack go
# to that Application's spec.source.kustomize.patches as a single list.
#
# When a stack has no deployments configured (or `deployments:` is
# absent entirely), its patches array is set to [] explicitly, which
# CLEARS any previously injected mounts. Re-running bootstrap with
# fewer mounts in host-config reverts the cluster to that smaller set.

deployments_phase() {
  if [ "$SKIP_DEV_MOUNTS" = 1 ]; then phase "phase 11: deployments  (skipped)"; return; fi
  phase "phase 11: deployments (inject kustomize.patches per stack)"

  # Same dry-run/canonical fallback as image_overrides.
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi

  # Get patches grouped by owning stack as JSON, e.g.
  # [{"stack":"core","patches":[{target,patch},...]}, ...]
  # The helper always emits an entry per known stack (with empty list
  # if no deployments target it), so we iterate predictably.
  local patches_json
  if [ -r "$hc" ]; then
    local stderr_capture
    stderr_capture="$(mktemp)"
    if ! patches_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-deployment-patches-json 2>"$stderr_capture")"; then
      fail "host-config deployments parse error:"
      cat "$stderr_capture" >&2
      rm -f "$stderr_capture"
      return
    fi
    # Surface privileged warnings to the operator loud and clear.
    if [ -s "$stderr_capture" ]; then
      while IFS= read -r line; do
        printf '  \033[33m%s\033[0m\n' "$line" >&2
      done < "$stderr_capture"
    fi
    rm -f "$stderr_capture"
  else
    # No host-config — synthesize a clear-all payload for every known stack.
    patches_json='[{"stack":"core","patches":[]}]'
  fi

  if [ "$DRY_RUN" = 1 ]; then
    ROBOT="$ROBOT" python3 - "$patches_json" <<'PY'
import json, os, sys
robot = os.environ["ROBOT"]
data = json.loads(sys.argv[1])
for entry in data:
    stack = entry["stack"]
    app = f"phantomos-{robot}-{stack}"
    n = len(entry["patches"])
    if n == 0:
        print(f"  DRY-RUN  patch {app}: clear kustomize.patches (set to [])")
    else:
        targets = ", ".join(p["target"]["name"] for p in entry["patches"])
        print(f"  DRY-RUN  patch {app}: kustomize.patches = {n} target(s) ({targets})")
PY
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch Applications"
    return
  fi

  # Iterate stacks; for each, build the {patches: [...]} merge patch
  # and apply it. Empty list clears prior injections.
  local entries
  entries="$(printf '%s' "$patches_json" | python3 -c 'import json,sys; print("\n".join(json.dumps(e) for e in json.load(sys.stdin)))')"
  while IFS= read -r entry_json; do
    [ -z "$entry_json" ] && continue
    local stack
    stack="$(printf '%s' "$entry_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["stack"])')"
    local target_app="phantomos-$ROBOT-$stack"

    if ! "${KUBECTL[@]}" -n argocd get app "$target_app" >/dev/null 2>&1; then
      info "$target_app not present (stack disabled?) — skipping"
      continue
    fi

    local patches_only_json
    patches_only_json="$(printf '%s' "$entry_json" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["patches"]))')"
    local patch
    patch=$(printf '{"spec":{"source":{"kustomize":{"patches":%s}}}}' "$patches_only_json")

    if "${KUBECTL[@]}" -n argocd patch app "$target_app" \
         --type=merge -p "$patch" >/dev/null; then
      if [ "$patches_only_json" = "[]" ]; then
        pass "cleared kustomize.patches on $target_app"
      else
        local count
        count="$(printf '%s' "$patches_only_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
        pass "patched $target_app  kustomize.patches ($count target(s) injected)"
      fi
    else
      fail "kubectl patch app $target_app failed"
      continue
    fi

    "${KUBECTL[@]}" -n argocd patch app "$target_app" \
      --type=merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 \
      && pass "triggered sync of $target_app"
  done <<< "$entries"
}

# ---- phase 9: argocd admin (install CLI + reset password) -------------

# Installs the argocd CLI binary (latest release from GitHub) and resets
# the admin password by writing a bcrypt hash into argocd-secret. Done
# as a script step rather than via `argocd account update-password` so
# we don't need a port-forward + login round-trip.
#
# Password source:
#   1. Interactive TTY → prompt twice (echo off), default to "1984" on
#      empty input (first bringup convenience).
#   2. Non-interactive (no TTY, e.g. CI / piped) → use "1984".
#
# Deliberately no env-var override: typing a secret on the command line
# leaks it to shell history and ps listings. `--argocd-admin`
# inherits a TTY, so password rotation prompts as expected.
_argocd_default_password="1984"

argocd_admin() {
  if [ "$SKIP_ARGOCD_ADMIN" = 1 ]; then phase "phase 9: argocd admin  (skipped)"; return; fi
  phase "phase 9: argocd admin (install CLI + set admin password)"

  # 1) install argocd CLI if missing
  #
  # Verifies the binary actually runs after install — partial downloads
  # otherwise leave a broken /usr/local/bin/argocd that fails silently
  # at first use. Up to two attempts before giving up.
  local argocd_bin=/usr/local/bin/argocd
  local installed_ok=0
  if command -v argocd >/dev/null 2>&1 && argocd version --client >/dev/null 2>&1; then
    skip "argocd CLI already in PATH ($(argocd version --client --short 2>/dev/null || echo present))"
    installed_ok=1
  else
    local argo_arch=""
    case "$(uname -m)" in
      x86_64)  argo_arch=amd64 ;;
      aarch64) argo_arch=arm64 ;;
      *)       fail "no argocd CLI binary for arch $(uname -m)" ;;
    esac
    if [ -n "$argo_arch" ]; then
      local url="https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${argo_arch}"
      if [ "$DRY_RUN" = 1 ]; then
        info "DRY-RUN  download $url -> $argocd_bin"
        installed_ok=1
      else
        local attempt
        for attempt in 1 2; do
          rm -f /tmp/argocd
          if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 \
               "$url" -o /tmp/argocd \
             && [ -s /tmp/argocd ] \
             && install -m 0555 /tmp/argocd "$argocd_bin" \
             && "$argocd_bin" version --client >/dev/null 2>&1; then
            pass "argocd CLI installed ($("$argocd_bin" version --client --short 2>/dev/null || echo ok))"
            rm -f /tmp/argocd
            installed_ok=1
            break
          fi
          if [ "$attempt" = 1 ]; then
            info "argocd download/verify failed; retrying once..."
            # If a broken binary was placed, get rid of it before retry.
            [ -f "$argocd_bin" ] && ! "$argocd_bin" version --client >/dev/null 2>&1 \
              && rm -f "$argocd_bin"
            sleep 3
          fi
        done
        rm -f /tmp/argocd
        if [ "$installed_ok" = 0 ]; then
          fail "argocd CLI install failed after 2 attempts ($url) — manual fix: sudo curl -fsSL -o $argocd_bin $url && sudo chmod +x $argocd_bin"
        fi
      fi
    fi
  fi

  # 2) acquire the password (prompt if interactive, default otherwise)
  local pw=""
  if [ "$DRY_RUN" = 1 ]; then
    pw="$_argocd_default_password"
    info "DRY-RUN  prompt for admin password (would default to '$pw' on empty input)"
    info "DRY-RUN  patch argocd-secret with bcrypt(\$pw)"
    return
  fi

  if [ -t 0 ] && [ -t 2 ]; then
    local pw_a pw_b
    while :; do
      printf '  argocd admin password [%s]: ' "$_argocd_default_password" >&2
      stty -echo 2>/dev/null || true
      IFS= read -r pw_a || pw_a=""
      stty echo 2>/dev/null || true
      printf '\n' >&2
      pw_a="${pw_a:-$_argocd_default_password}"

      printf '  confirm: ' >&2
      stty -echo 2>/dev/null || true
      IFS= read -r pw_b || pw_b=""
      stty echo 2>/dev/null || true
      printf '\n' >&2
      pw_b="${pw_b:-$_argocd_default_password}"

      if [ "$pw_a" = "$pw_b" ]; then
        pw="$pw_a"
        break
      fi
      printf '  passwords do not match — try again\n' >&2
    done
  else
    pw="$_argocd_default_password"
    info "non-interactive shell — using default admin password"
  fi

  # 3) reset admin password by patching argocd-secret
  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch argocd-secret"
    return
  fi

  if ! "${KUBECTL[@]}" -n argocd get secret argocd-secret >/dev/null 2>&1; then
    fail "argocd-secret not found in argocd ns — gitops phase must run first"
    return
  fi

  # bcrypt the password. Prefer htpasswd (apache2-utils); install on demand
  # since phase 2 doesn't pull it in.
  if ! command -v htpasswd >/dev/null 2>&1; then
    info "installing apache2-utils (for htpasswd)"
    apt-get install -y apache2-utils >/dev/null 2>&1 || true
  fi
  if ! command -v htpasswd >/dev/null 2>&1; then
    fail "htpasswd unavailable — install apache2-utils manually and re-run --argocd-admin"
    return
  fi

  local hash mtime
  hash=$(htpasswd -nbBC 10 "" "$pw" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
  mtime=$(date +%FT%T%Z)

  if "${KUBECTL[@]}" -n argocd patch secret argocd-secret --type merge \
       -p "{\"stringData\":{\"admin.password\":\"$hash\",\"admin.passwordMtime\":\"$mtime\"}}" >/dev/null; then
    pass "argocd admin password updated"
    # initial-admin-secret is no longer authoritative once admin.password
    # is rotated. Drop it so future operators don't try to use it.
    "${KUBECTL[@]}" -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null 2>&1 || true
  else
    fail "could not patch argocd-secret"
  fi
}

# ---- phase 12: setup-positronic (optional) --------------------------------

setup_positronic() {
  if [ "$SETUP_POSITRONIC" = 0 ]; then return; fi
  phase "phase 12: setup-positronic"

  if [ -z "$POSITRONIC_IMAGE" ]; then
    fail "--setup-positronic requires --positronic-image <image>"
    return
  fi

  local script="$REPO_ROOT/scripts/positronic.sh"
  if [ ! -f "$script" ]; then
    fail "scripts/positronic.sh not found"; return
  fi

  # Push the positronic-control image to the local registry.
  info "pushing $POSITRONIC_IMAGE via positronic.sh"
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  bash $script --robot $ROBOT push-image $POSITRONIC_IMAGE --no-redeploy"
  else
    if bash "$script" --robot "$ROBOT" push-image "$POSITRONIC_IMAGE" --no-redeploy; then
      pass "positronic-control image pushed"
    else
      fail "positronic-control image push failed"
    fi
  fi

  # Build phantom-models (interactive by default; --all for non-interactive).
  local build_script="$REPO_ROOT/scripts/phantom-models/build.py"
  if [ ! -f "$build_script" ]; then
    fail "scripts/phantom-models/build.py not found"; return
  fi

  info "building phantom-models image"
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  python3 $build_script --all"
  else
    if python3 "$build_script" --all; then
      pass "phantom-models image built and pushed"
    else
      fail "phantom-models build failed"
    fi
  fi

  # Redeploy now that both images are in the registry.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  bash $script --robot $ROBOT redeploy"
  else
    if bash "$script" --robot "$ROBOT" redeploy; then
      pass "positronic-control redeployed"
    else
      fail "positronic-control redeploy failed"
    fi
  fi
}

# ---- phase 13: validate --------------------------------------------------

validate() {
  if [ "$SKIP_VALIDATE" = 1 ]; then phase "phase 13: validate  (skipped)"; return; fi
  phase "phase 13: validate"

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  bash $REPO_ROOT/scripts/validate-local-registry.sh"
    return
  fi

  if [ ! -x "$REPO_ROOT/scripts/validate-local-registry.sh" ]; then
    skip "scripts/validate-local-registry.sh not found/executable"
    return
  fi

  if bash "$REPO_ROOT/scripts/validate-local-registry.sh"; then
    pass "validate-local-registry: 0 failures"
  else
    fail "validate-local-registry: $? failures"
  fi
}

# ---- main ---------------------------------------------------------------

print_plan() {
  # Each line shows whether a phase is going to run (✓) or be skipped
  # (─), with a dim "(reason)" when skipped. Aligned by padding the
  # label column. Adapted from main's print_plan + extended for our
  # extra phases (operator-ui-config, install-dma-ethercat,
  # argocd-admin, image-overrides, deployments).
  _step() {
    local on=$1 label=$2 why=$3
    if [ "$on" = "1" ]; then
      printf '   \033[32m✓\033[0m  %s\n' "$label"
    elif [ -n "$why" ]; then
      printf '   \033[2m─  %-44s  %s\033[0m\n' "$label" "($why)"
    else
      printf '   \033[2m─  %s\033[0m\n' "$label"
    fi
  }

  printf '\n'
  printf '\033[1;36m──\033[0m \033[1mbootstrap-robot.sh\033[0m  robot=\033[36m%s\033[0m' "${ROBOT:-<not required for selected phases>}"
  [ "$DRY_RUN" = 1 ] && printf '  \033[33m(dry-run)\033[0m'
  printf '\n'
  printf '   \033[2mrepo:\033[0m         %s\n' "$REPO_ROOT"
  printf '   \033[2mhost-config:\033[0m  %s\n' \
    "$([ -r "$HOST_CONFIG_FILE" ] && echo "$HOST_CONFIG_FILE" || echo "<missing — wizard will run>")"
  printf '   \033[2mai_pc_url:\033[0m    %s\n' "${AI_PC_URL:-<from $PAIRING_FILE>}"

  if [ "$RESET" = 1 ]; then
    printf '\n   \033[1mRESET (purge cluster + exit; re-run without --reset to rebuild)\033[0m\n\n'
    return
  fi

  printf '\n   \033[1mplanned phases (in execution order):\033[0m\n'

  _step $([ "$SKIP_DOCKER_STOP"          = 0 ] && echo 1 || echo 0) "stop docker containers"                 "--skip-docker-stop"
  _step $([ "$SKIP_STOP_SERVICES"        = 0 ] && echo 1 || echo 0) "stop system services"                   "--skip-stop-services"
  _step $([ "$SKIP_ETHERCAT_UNINSTALL"   = 0 ] && echo 1 || echo 0) "uninstall dma-ethercat"                 "--skip-ethercat-uninstall"
  _step 1                                                           "phase  1  preflight"                    ""
  _step 1                                                           "          configure-host (if missing)"  ""
  _step $([ "$SKIP_DEPS"                 = 0 ] && echo 1 || echo 0) "phase  2  deps"                         "--deps not selected"
  _step $([ "$SKIP_CLUSTER"              = 0 ] && echo 1 || echo 0) "phase  3  cluster"                      "--cluster not selected"
  _step $([ "$SKIP_HOST"                 = 0 ] && echo 1 || echo 0) "phase  4  host config"                  "--host not selected"
  _step $([ "$SKIP_SEED_PULL_SECRETS"    = 0 ] && echo 1 || echo 0) "phase  5  seed pull secrets"            "--seed-pull-secrets not selected"
  _step $([ "$SKIP_OPERATOR_UI_CONFIG"   = 0 ] && echo 1 || echo 0) "phase  6  operator-ui-config"           "--operator-ui-config not selected"
  _step $([ "$SKIP_INSTALL_DMA_ETHERCAT" = 0 ] && echo 1 || echo 0) "phase  7  install dma-ethercat (gates 8)" "--install-dma-ethercat not selected"
  _step $([ "$SKIP_GITOPS"               = 0 ] && echo 1 || echo 0) "phase  8  gitops"                       "--gitops not selected"
  _step $([ "$SKIP_ARGOCD_ADMIN"         = 0 ] && echo 1 || echo 0) "phase  9  argocd-admin"                 "--argocd-admin not selected"
  _step $([ "$SKIP_IMAGE_OVERRIDES"      = 0 ] && echo 1 || echo 0) "phase 10  image-overrides"              "--image-overrides not selected"
  _step $([ "$SKIP_DEV_MOUNTS"           = 0 ] && echo 1 || echo 0) "phase 11  deployments"                  "--deployments not selected"
  _step "$SETUP_POSITRONIC"                                         "phase 12  setup-positronic"             "--setup-positronic not set"
  _step $([ "$SKIP_VALIDATE"             = 0 ] && echo 1 || echo 0) "phase 13  validate"                     "--validate not selected"
  printf '\n'
}

print_plan

# When --reset is set, it has its own confirmation prompt with a
# detailed warning. Skip the generic confirmation.
if [ "$YES" = 0 ] && [ "$DRY_RUN" = 0 ] && [ "$RESET" = 0 ]; then
  printf '\nProceed? [y/N] '
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]] || { echo "aborted"; exit 1; }
fi

purge_docker            ; guard
stop_existing_services  ; guard
reset_cluster           ; guard

# --reset is a destructive purge that exits before bootstrapping a fresh
# cluster. Re-run without --reset to rebuild. Splitting the two passes
# gives the operator a chance to pull / edit / inspect between the
# purge and the rebuild, and avoids surprising people who pass --reset
# expecting "just clean up".
if [ "$RESET" = 1 ]; then
  printf '\nreset complete. Re-run without --reset to bootstrap a fresh cluster.\n'
  summary
  exit "$FAIL"
fi

uninstall_ethercat ; guard
preflight          ; guard

# Drive the wizard if /etc/phantomos/host-config.yaml is missing.
# Every phase past deps reads this file (gitops, operator-ui-config,
# image-overrides, deployments, install-dma-ethercat) so the wizard
# must run before they do. Idempotent when host-config already exists.
configure_host_ensure_present ; guard

# Persist the resolved robot identity to /etc/phantomos/robot so future
# script runs on this host don't need --robot. Skipped in dry-run, and
# when the selected phases don't require a robot.
if [ "$DRY_RUN" = 0 ] && [ -n "${ROBOT:-}" ]; then
  if persist_robot "$ROBOT"; then
    pass "robot identity persisted: $ROBOT_ID_FILE -> $ROBOT"
  else
    fail "could not write $ROBOT_ID_FILE"
  fi
fi
guard

deps               ; guard
cluster            ; guard
host_config        ; guard
seed_pull_secrets  ; guard
operator_ui_config ; guard
install_dma_ethercat ; guard
gitops             ; guard
argocd_admin       ; guard
image_overrides    ; guard
deployments_phase  ; guard
setup_positronic   ; guard
validate

summary
exit "$FAIL"
