#!/usr/bin/env bash
# bootstrap-robot.sh — bring a fresh machine to a working k0s + ArgoCD
# state for this fleet. Idempotent: re-running on a bootstrapped host
# detects existing config and skips destructive steps.
#
# Usage:
#   sudo bash scripts/bootstrap-robot.sh --robot <name> [flags]
#
# Required:
#   --robot <name>     Robot identifier; must match a directory under
#                      manifests/robots/ (e.g. ak-007, mk09). Also the
#                      Application name expected at
#                      gitops/apps/<name>/phantomos-<name>.yaml.
#
# Flags:
#   -y, --yes          skip confirmation prompts
#   --dry-run          print what each phase would do, change nothing
#   --keep-going       continue after failures (default: bail at first)
#   --skip-docker-stop
#                      Skip the docker pre-phase. By DEFAULT the script
#                      sends `docker stop` to every running container on
#                      the host so they release ports / device handles /
#                      mounts before the next phase. This is non-
#                      destructive (containers and images stay; they can
#                      be `docker start`-ed again). Already a no-op if
#                      docker is not installed or no containers are
#                      running, so this flag is mainly for when you have
#                      docker workloads on the host that must keep
#                      running through the bootstrap.
#   --skip-stop-services
#                      Skip the host-systemd cleanup pre-phase. By
#                      DEFAULT, right after the docker-stop pre-phase,
#                      the script lists enabled services via
#                      `systemctl list-unit-files --state=enabled` and
#                      stops + disables anything matching `*api*server*`
#                      or `*dma*ethercat*` (separator-agnostic — picks
#                      up hyphen, underscore, dot, or no-separator
#                      variants). This catches host-systemd
#                      copies of services that the cluster will manage
#                      (api-server pods) or re-install (dma-ethercat),
#                      so they don't fight the pod-managed copy for
#                      ports / device handles.
#   --skip-ethercat-uninstall
#                      Skip the dma-ethercat teardown pre-phase. By
#                      DEFAULT, after the docker stop / reset pre-phases
#                      (so pods are gone first), the script checks for
#                      `dma-ethercat.service`: if active it stops it, if
#                      enabled it disables it, then runs
#                      `/usr/sbin/dma-ethercat-uninstall`. Each step is a
#                      no-op when already in the desired state. Use this
#                      flag on a routine re-bootstrap of a healthy robot
#                      where you want to leave the realtime stack alone.
#   --skip-ethercat-install
#                      Skip the dma-ethercat install phase. By DEFAULT,
#                      AFTER phase 5 (seed pull secrets) and BEFORE
#                      phase 6 (gitops), the script applies the
#                      manifests/installers/dma-ethercat/robots/<robot>/
#                      kustomization (a one-shot k8s Job using the
#                      foundationbot/dma-ethercat image), waits for the
#                      Job to copy /usr/local/share/dma/deb/*.deb to
#                      /var/lib/dma-ethercat-installer/ on the host,
#                      then runs `dpkg -i` on the .deb and
#                      `systemctl enable --now dma-ethercat.service`.
#                      Failure at ANY of those steps halts the bootstrap
#                      with a DMA-ETHERCAT FAILURE banner and gitops is
#                      NOT run — positronic-control / dma-video / nimbus
#                      pods only come up after the realtime stack is
#                      healthy. Use this flag to bypass that gate (e.g.
#                      operator already installed the .deb manually).
#                      The Job is bootstrap-managed (not in ArgoCD) so
#                      every bootstrap forces a fresh extract via
#                      delete-then-apply. Robot overlay must exist at
#                      manifests/installers/dma-ethercat/robots/<robot>/.
#   --reset            BEFORE phase 1, tear down any pre-existing k0s
#                      cluster (`k0s stop && k0s reset`) and back up
#                      /root/.kube/config and terraform/terraform.tfstate*
#                      to .bak.<timestamp>. Then run the rest of the
#                      bootstrap normally. Cluster workload state is
#                      destroyed; on-disk hostPath data under
#                      /var/lib/k0s-data/, /var/lib/registry/, and
#                      /var/lib/recordings/ is preserved (k0s reset does
#                      not touch those paths).
#   --skip-deps        skip phase 2 (apt installs + k0s/terraform binaries)
#   --skip-host        skip phase 3 (host containerd/nvidia config)
#   --skip-cluster     skip phase 4 (k0s install + systemd start)
#   --skip-seed-pull-secrets
#                      skip phase 5 (propagate dockerhub-creds Secret to
#                      argus / dma-video / nimbus namespaces)
#   --skip-gitops      skip phase 6 (terraform apply)
#   --skip-nvidia      force-skip nvidia runtime config (overrides
#                      hardware autodetect)
#   --skip-validate    skip the final validate-local-registry.sh run
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
#   --seed-pull-secrets-only
#                      run ONLY phase 5 (seed pull secrets) on an already-
#                      bootstrapped cluster, then exit. Useful when a robot
#                      came up before the operator had the credential, or
#                      to recover from `ImagePullBackOff` after rotating
#                      the foundationbot PAT. Skips preflight/deps/host
#                      config/cluster/gitops/validate.
#   -h, --help         this help
#
# Phases:
#   1. preflight    OS / arch / kernel / disk / sudo / port collisions
#   2. deps         apt: docker.io, skopeo, python3, curl, jq, git,
#                   pciutils, unzip; k0s binary; terraform binary
#   3. host config  configure-k0s-containerd-mirror.sh +
#                   configure-k0s-nvidia-runtime.sh (if a GPU is detected
#                   via lspci or /dev/nvidia0)
#   4. cluster      k0s install controller --single --enable-worker;
#                   systemctl enable --now k0scontroller; wait Ready;
#                   write /root/.kube/config from `k0s kubeconfig admin`
#                   (so kubectl + terraform have a config to read)
#   5. seed pull secrets
#                   ensure `dockerhub-creds` (kubernetes.io/dockerconfigjson)
#                   exists in `argus`, `dma-video`, `nimbus` so private
#                   foundationbot/* images can be pulled. Source order:
#                   --dockerhub-secret-file, then ~/.docker/config.json
#                   (default), then existing Secret in the `phantom`
#                   namespace, then no-op if already present in every
#                   target namespace. Creates the namespace if it doesn't
#                   exist yet. Idempotent.
#   6. gitops       cd terraform && terraform init && terraform apply
#                   (installs ArgoCD via the official Helm chart and
#                   applies gitops/root-app.yaml — the canonical path).
#                   Wait for phantomos-<robot> to reach Synced + Healthy.
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
SKIP_DOCKER_STOP=0
SKIP_STOP_SERVICES=0
SKIP_ETHERCAT_UNINSTALL=0
SKIP_ETHERCAT_INSTALL=0
RESET=0
SKIP_DEPS=0
SKIP_HOST=0
SKIP_CLUSTER=0
SKIP_SEED_PULL_SECRETS=0
SKIP_GITOPS=0
SKIP_NVIDIA=0
SKIP_VALIDATE=0
SETUP_POSITRONIC=0
POSITRONIC_IMAGE=""
DOCKERHUB_SECRET_FILE=""
SEED_PULL_SECRETS_ONLY=0

# Namespaces that pull `foundationbot/*` images and therefore need the
# dockerhub-creds Secret. Kept in sync with REQUIREMENTS.md and with the
# `imagePullSecrets:` references in manifests/base/{argus,dma-video,nimbus}/
# and manifests/installers/dma-ethercat/base/job.yaml (phantom).
PULL_SECRET_NAMESPACES=(argus dma-video nimbus phantom)
PULL_SECRET_NAME="dockerhub-creds"

while [ $# -gt 0 ]; do
  case "$1" in
    --robot)         ROBOT="${2:-}"; shift 2 ;;
    -y|--yes)        YES=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --keep-going)    KEEP_GOING=1; shift ;;
    --skip-docker-stop)
                     SKIP_DOCKER_STOP=1; shift ;;
    --skip-stop-services)
                     SKIP_STOP_SERVICES=1; shift ;;
    --skip-ethercat-uninstall)
                     SKIP_ETHERCAT_UNINSTALL=1; shift ;;
    --skip-ethercat-install)
                     SKIP_ETHERCAT_INSTALL=1; shift ;;
    --reset)         RESET=1; shift ;;
    --skip-deps)     SKIP_DEPS=1; shift ;;
    --skip-host)     SKIP_HOST=1; shift ;;
    --skip-cluster)  SKIP_CLUSTER=1; shift ;;
    --skip-seed-pull-secrets)
                     SKIP_SEED_PULL_SECRETS=1; shift ;;
    --skip-gitops)   SKIP_GITOPS=1; shift ;;
    --skip-nvidia)   SKIP_NVIDIA=1; shift ;;
    --skip-validate) SKIP_VALIDATE=1; shift ;;
    --setup-positronic)
                     SETUP_POSITRONIC=1; shift ;;
    --positronic-image)
                     POSITRONIC_IMAGE="${2:-}"; shift 2 ;;
    --dockerhub-secret-file)
                     DOCKERHUB_SECRET_FILE="${2:-}"; shift 2 ;;
    --seed-pull-secrets-only)
                     SEED_PULL_SECRETS_ONLY=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ---- helpers ------------------------------------------------------------

PASS=0; FAIL=0; SKIP=0
pass()   { PASS=$((PASS + 1)); printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; }
fail()   { FAIL=$((FAIL + 1)); printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; }
skip()   { SKIP=$((SKIP + 1)); printf '  \033[33m• SKIP\033[0m  %s\n' "$1"; }
info()   { printf '  \033[2m·\033[0m %s\n' "$1"; }
note()   { printf '  \033[36m→\033[0m %s\n' "$1"; }   # action announcement (e.g. "stopping 3 containers...")
phase()  { printf '\n\033[1;36m──\033[0m \033[1m%s\033[0m\n' "$1"; }
die()    { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }

# Bail early on FAIL unless --keep-going is set.
guard() { [ "$FAIL" -gt 0 ] && [ "$KEEP_GOING" = 0 ] && summary && exit "$FAIL"; }

# Hard-stop helper for the dma-ethercat install path. The realtime
# stack must be healthy before the rest of the gitops-managed pods come
# up — positronic-control and friends talk to the EtherCAT bus via the
# dma_main binary the .deb installs. On any failure here we abort the
# bootstrap with a dedicated banner so the cause isn't buried under
# noise from downstream phases that would otherwise still run under
# --keep-going. Intentionally bypasses the --keep-going semantics that
# guard() respects: ethercat is non-negotiable.
ethercat_die() {
  printf '\n  \033[31mDMA-ETHERCAT FAILURE\033[0m  %s\n' "$1" >&2
  printf '  bootstrap halted — gitops and downstream pods are NOT applied\n' >&2
  printf '  until the realtime stack is healthy. fix the underlying issue\n' >&2
  printf '  and re-run, or pass --skip-ethercat-install to bypass.\n' >&2
  summary
  exit "${FAIL:-1}"
}

summary() {
  printf '\n==> summary\n  PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
}

# ---- preconditions ------------------------------------------------------

# --seed-pull-secrets-only is namespace-level work — no robot context
# needed. The other invocations all need to know which robot's overlay
# they're applying.
if [ "$SEED_PULL_SECRETS_ONLY" = 0 ] && [ -z "$ROBOT" ]; then
  usage >&2
  printf '\nerror: --robot <name> is required\n' >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || die "cd $REPO_ROOT"

if [ "$SEED_PULL_SECRETS_ONLY" = 0 ] && [ ! -d "$REPO_ROOT/manifests/robots/$ROBOT" ]; then
  available=$(ls "$REPO_ROOT/manifests/robots/" 2>/dev/null | tr '\n' ' ')
  die "manifests/robots/$ROBOT/ not found — typo? available: ${available:-<none>}"
fi

if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "must run as root (try: sudo bash $0 --robot $ROBOT ...)"
fi

# kubectl resolution (may not exist yet on a fresh machine; fall back later)
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v k0s >/dev/null 2>&1; then
  KUBECTL=(k0s kubectl)
else
  KUBECTL=()
fi

# ---- pre-phase: stop docker containers (default; --skip-docker-stop) ---

# Send `docker stop` to every running container so they release ports,
# device handles, and bind mounts before the rest of bootstrap proceeds.
# Non-destructive: containers and images are left in place and can be
# `docker start`-ed again afterward. Runs by default; --skip-docker-stop
# opts out. Top-level "Proceed?" prompt already gates execution, so this
# function does not prompt again.
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

# ---- pre-phase: stop+disable enabled api-server / dma-ethercat services

# Walk `systemctl list-unit-files --state=enabled --type=service` and
# stop + disable anything matching `*api-server*` or `dma*ethercat*`.
# These are host-systemd copies of services the cluster will own once
# the bootstrap finishes:
#   - api-server  -> brought up as a pod by the gitops phase; the host
#                    copy listening on the same port would block the
#                    Service / collide on dependencies.
#   - dma-ethercat -> uninstalled by the next pre-phase and reinstalled
#                    fresh from the .deb baked into the foundationbot
#                    image; stopping it here ensures phase 4 (cluster)
#                    never sees the running unit.
# Idempotent: a service that's already stopped/disabled produces a
# no-op and we move on. Failures are recorded but do not abort — we'd
# rather get to the cluster phase and let the operator deal with a
# stubborn unit than wedge here on a transient systemd hiccup.
stop_existing_services() {
  if [ "$SKIP_STOP_SERVICES" = 1 ]; then
    phase "pre-phase: stop api-server / dma-ethercat services  (skipped — --skip-stop-services)"
    return
  fi
  phase "pre-phase: stop api-server / dma-ethercat services"

  if ! command -v systemctl >/dev/null 2>&1; then
    skip "systemctl not present — nothing to do"
    return
  fi

  # Naming-convention-agnostic match. The ERE `.*` between tokens
  # corresponds to the shell-glob `*` between substrings, so all of
  # these match the api branch:
  #   api-server, api_server, api.server, apiserver,
  #   phantomos-api-server, my.api.rest.server, ...
  # And all of these match the dma branch:
  #   dma-ethercat, dma_ethercat, dma.ethercat, dmaethercat, ...
  # `-i` makes the match case-insensitive (Api-Server, DMA-EtherCAT, …).
  # No anchors — the substrings can appear anywhere in the unit name.
  local matches
  matches=$(systemctl list-unit-files --state=enabled --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | grep -iE '(api.*server|dma.*ethercat)' \
    || true)

  if [ -z "$matches" ]; then
    skip "no enabled api-server / dma-ethercat services on this host"
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
  #    behind. Phase 4's "already installed" check is keyed on this file,
  #    so leaving it in place causes phase 4 to skip `k0s install controller`
  #    (the step that creates the systemd unit) and then fail the
  #    `systemctl enable --now k0scontroller` that follows.
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
  #    is no longer valid until phase 4 reinstalls it.
  KUBECTL=()
}

# ---- pre-phase: uninstall dma-ethercat (default; --skip-ethercat-uninstall)

# Tear down the dma-ethercat realtime control service. Runs by default;
# --skip-ethercat-uninstall opts out (use it for routine re-bootstraps
# where the realtime stack should stay in place). Designed to run AFTER
# purge_docker and reset_cluster so the pods that talk to ethercat are
# already gone — stopping the service while pods are still pinging its
# socket can leave the kernel module in a wedged state.
#
# Sequence (each step independent + idempotent):
#   1. if no unit file installed                  -> skip whole phase
#   2. if active                                  -> systemctl stop
#   3. if stop failed                             -> bail (do NOT disable
#                                                   or run uninstaller —
#                                                   leaving the service
#                                                   half-torn-down is
#                                                   worse than no-op)
#   4. if enabled / enabled-runtime / alias       -> systemctl disable
#   5. if /usr/sbin/dma-ethercat-uninstall exists -> run it
uninstall_ethercat() {
  if [ "$SKIP_ETHERCAT_UNINSTALL" = 1 ]; then
    phase "pre-phase: uninstall dma-ethercat  (skipped — --skip-ethercat-uninstall)"
    return
  fi
  phase "pre-phase: uninstall dma-ethercat"

  local svc=dma-ethercat.service
  local uninstaller=/usr/sbin/dma-ethercat-uninstall

  if ! systemctl list-unit-files "$svc" 2>/dev/null | grep -q "^$svc"; then
    skip "$svc unit not installed — nothing to tear down"
    if [ -x "$uninstaller" ]; then
      note "running $uninstaller anyway (cleanup of stray files)..."
      if [ "$DRY_RUN" = 1 ]; then
        note "DRY-RUN: $uninstaller"
      elif "$uninstaller"; then
        pass "$uninstaller completed"
      else
        fail "$uninstaller exited non-zero"
      fi
    fi
    return
  fi

  local active enabled
  active=$(systemctl is-active  "$svc" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)
  note "current state: active=${active:-unknown}  enabled=${enabled:-unknown}"

  if [ "$DRY_RUN" = 1 ]; then
    [ "$active" = "active" ]              && note "DRY-RUN: systemctl stop $svc"
    [[ "$enabled" =~ ^enabled ]]          && note "DRY-RUN: systemctl disable $svc"
    [ -x "$uninstaller" ]                 && note "DRY-RUN: $uninstaller"
    return
  fi

  # 1. stop (only if active)
  if [ "$active" = "active" ]; then
    note "stopping $svc..."
    if systemctl stop "$svc"; then
      pass "stopped  $svc"
    else
      fail "stop $svc — refusing to disable/uninstall a running service"
      return
    fi
  else
    skip "stop     $svc  (not active)"
  fi

  # 2. disable (only if enabled in some form)
  # `is-enabled` returns 'enabled', 'enabled-runtime', 'alias', etc. when
  # there's something to disable. 'static', 'masked', 'disabled' are no-op.
  if [[ "$enabled" =~ ^(enabled|enabled-runtime|alias)$ ]]; then
    if systemctl disable "$svc" 2>/dev/null; then
      pass "disabled $svc"
    else
      fail "disable  $svc"
      return
    fi
  else
    skip "disable  $svc  (state=${enabled:-unknown})"
  fi

  # 3. run the uninstaller
  if [ ! -e "$uninstaller" ]; then
    fail "$uninstaller not found — cannot complete uninstall"
    return
  fi
  if [ ! -x "$uninstaller" ]; then
    fail "$uninstaller not executable"
    return
  fi
  note "running $uninstaller..."
  if "$uninstaller"; then
    pass "$uninstaller completed"
  else
    fail "$uninstaller exited non-zero"
  fi
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

# ---- phase 3: host config -----------------------------------------------

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
  if [ "$SKIP_HOST" = 1 ]; then phase "phase 3: host config  (skipped)"; return; fi
  phase "phase 3: host config"

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
}

# ---- phase 4: cluster ---------------------------------------------------

cluster() {
  if [ "$SKIP_CLUSTER" = 1 ]; then phase "phase 4: cluster  (skipped)"; return; fi
  phase "phase 4: cluster"

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
  # --seed-pull-secrets-only on a host where /usr/local/bin/kubectl was
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

# ---- phase 6: gitops ----------------------------------------------------

gitops() {
  if [ "$SKIP_GITOPS" = 1 ]; then phase "phase 6: gitops  (skipped)"; return; fi
  phase "phase 6: gitops (terraform)"

  if [ ! -f "$REPO_ROOT/gitops/apps/$ROBOT/phantomos-$ROBOT.yaml" ]; then
    fail "gitops/apps/$ROBOT/phantomos-$ROBOT.yaml not in repo — create it before re-running"
    return
  fi

  if [ ! -d "$REPO_ROOT/terraform" ]; then
    fail "terraform/ not found at $REPO_ROOT/terraform"; return
  fi

  if ! command -v terraform >/dev/null 2>&1 && [ "$DRY_RUN" = 0 ]; then
    fail "terraform not in PATH — phase 2 should have installed it"; return
  fi

  local kc=/root/.kube/config
  if [ "$DRY_RUN" = 0 ] && [ ! -r "$kc" ]; then
    fail "$kc not readable — phase 4 should have written it"; return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  cd $REPO_ROOT/terraform && terraform init && terraform apply -auto-approve -var=kubeconfig=$kc"
    info "DRY-RUN  wait for phantomos-$ROBOT  Synced + Healthy"
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
  pass "terraform apply"

  info "waiting for phantomos-$ROBOT to reach Synced+Healthy..."
  local sync health
  for _ in $(seq 1 120); do
    sync=$("${KUBECTL[@]}" -n argocd get app "phantomos-$ROBOT" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$("${KUBECTL[@]}" -n argocd get app "phantomos-$ROBOT" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      pass "phantomos-$ROBOT  Synced + Healthy"
      return
    fi
    sleep 5
  done
  fail "phantomos-$ROBOT did not reach Synced+Healthy in 10min (sync=${sync:-?} health=${health:-?})"
}

# ---- phase 5.5: install dma-ethercat (default; --skip-ethercat-install)

# Install the dma-ethercat .deb that ships baked into the
# foundationbot/dma-ethercat container image, then enable + start the
# service. Runs strictly BEFORE phase 6 (gitops) — the realtime stack
# must be up before positronic-control / dma-video / nimbus pods start
# because they talk to the EtherCAT bus through the dma_main binary
# this .deb installs.
#
# Any failure in this phase calls ethercat_die(): the bootstrap halts
# with a dedicated DMA-ETHERCAT FAILURE banner and gitops never runs,
# even under --keep-going. Pass --skip-ethercat-install if you need to
# bypass this gate (e.g. operator already installed the .deb manually).
#
# Flow:
#   1. ensure ns/phantom exists (so the Job can land there)
#   2. delete any prior dma-ethercat-installer Job — fresh extract every
#      bootstrap, per the design. The Job is NOT in ArgoCD; it lives at
#      manifests/installers/dma-ethercat/ specifically so the bootstrap
#      can manage it without racing Argo.
#   3. kubectl apply -k manifests/installers/dma-ethercat/robots/<robot>/
#   4. wait for Job to reach Complete (5 min cap; image pulls on a slow
#      link can dominate)
#   5. dpkg -i /var/lib/dma-ethercat-installer/dma-ethercat-*.deb
#   6. systemctl enable --now dma-ethercat.service
install_dma_ethercat() {
  if [ "$SKIP_ETHERCAT_INSTALL" = 1 ]; then phase "phase 5.5: install dma-ethercat  (skipped — --skip-ethercat-install)"; return; fi
  phase "phase 5.5: install dma-ethercat (gates phase 6)"

  local overlay="$REPO_ROOT/manifests/installers/dma-ethercat/robots/$ROBOT"
  if [ ! -d "$overlay" ]; then
    fail "$overlay not found"
    ethercat_die "missing robot overlay — add manifests/installers/dma-ethercat/robots/$ROBOT/ and pin the image tag"
  fi

  if [ "${#KUBECTL[@]}" -eq 0 ]; then
    fail "no kubectl/k0s available"
    ethercat_die "kubectl missing — phase 4 (cluster) should have set this up"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    note "DRY-RUN: kubectl create ns phantom (if missing)"
    note "DRY-RUN: kubectl -n phantom delete job dma-ethercat-installer --ignore-not-found"
    note "DRY-RUN: kubectl apply -k $overlay"
    note "DRY-RUN: kubectl -n phantom wait --for=condition=complete job/dma-ethercat-installer"
    note "DRY-RUN: dpkg -i /var/lib/dma-ethercat-installer/dma-ethercat-*.deb"
    note "DRY-RUN: systemctl enable --now dma-ethercat.service"
    return
  fi

  # 1. namespace
  if "${KUBECTL[@]}" get ns phantom >/dev/null 2>&1; then
    skip "ns/phantom already exists"
  else
    note "creating ns/phantom..."
    if "${KUBECTL[@]}" create ns phantom >/dev/null; then
      pass "ns/phantom created"
    else
      fail "could not create ns/phantom"
      ethercat_die "could not create ns/phantom — cluster may be unhealthy"
    fi
  fi

  # 2. force fresh extract — drop any prior Job (and its pod) before re-applying
  if "${KUBECTL[@]}" -n phantom get job dma-ethercat-installer >/dev/null 2>&1; then
    note "removing prior installer Job (forces fresh extract)..."
    "${KUBECTL[@]}" -n phantom delete job dma-ethercat-installer --ignore-not-found --wait=true >/dev/null 2>&1 || true
    pass "prior Job removed"
  else
    skip "no prior installer Job to remove"
  fi

  # 3. apply the per-robot kustomization
  note "applying installer manifest from $overlay..."
  if "${KUBECTL[@]}" apply -k "$overlay" >/dev/null; then
    pass "installer Job applied"
  else
    fail "kubectl apply -k $overlay"
    ethercat_die "could not apply installer Job — check kustomize render at $overlay"
  fi

  # 4. wait for completion (or surface failure)
  note "waiting up to 5min for installer Job to reach Complete..."
  if "${KUBECTL[@]}" -n phantom wait --for=condition=complete --timeout=300s job/dma-ethercat-installer >/dev/null 2>&1; then
    pass "installer Job Complete"
  else
    local jstat
    jstat=$("${KUBECTL[@]}" -n phantom get job dma-ethercat-installer -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}' 2>/dev/null || true)
    fail "installer Job did not Complete in 5min (status: ${jstat:-unknown})"
    info "pod logs:"
    "${KUBECTL[@]}" -n phantom logs -l app=dma-ethercat-installer --tail=50 2>&1 | sed 's/^/      /' || true
    ethercat_die "installer Job never reached Complete — likely image pull (check dockerhub-creds in phantom ns) or the .deb path inside the image"
  fi

  # 5. dpkg -i. Glob match: image bakes one .deb per arch — exactly one
  #    file should be present after the Job's `cp`.
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
    ethercat_die "dpkg -i failed — check above output for missing dependencies (libstdc++/libfoo) or conflicting packages"
  fi

  # 6. enable + start. Per the user's spec, "rest of the pods" only run
  #    after this succeeds — so a failed start halts the bootstrap.
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

# ---- phase 7: setup-positronic (optional) --------------------------------

setup_positronic() {
  if [ "$SETUP_POSITRONIC" = 0 ]; then return; fi
  phase "phase 7: setup-positronic"

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

# ---- phase 8: validate --------------------------------------------------

validate() {
  if [ "$SKIP_VALIDATE" = 1 ]; then phase "phase 8: validate  (skipped)"; return; fi
  phase "phase 8: validate"

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

# Standalone mode: only seed pull secrets, then exit. Used to fix an
# already-running cluster whose pods are stuck in ImagePullBackOff.
if [ "$SEED_PULL_SECRETS_ONLY" = 1 ]; then
  cat <<EOF
bootstrap-robot.sh — seed-pull-secrets-only $([ "$DRY_RUN" = 1 ] && echo "(dry-run)")
repo: $REPO_ROOT
namespaces: ${PULL_SECRET_NAMESPACES[*]}
source:    $([ -n "$DOCKERHUB_SECRET_FILE" ] && echo "$DOCKERHUB_SECRET_FILE" || echo "~/.docker/config.json (default), then phantom/$PULL_SECRET_NAME")
EOF
  seed_pull_secrets
  summary
  exit "$FAIL"
fi

cat <<EOF
bootstrap-robot.sh — robot=$ROBOT $([ "$DRY_RUN" = 1 ] && echo "(dry-run)")
repo: $REPO_ROOT
phases: $([ "$SKIP_DOCKER_STOP" = 0 ] && echo "STOP-DOCKER, ")$([ "$SKIP_STOP_SERVICES" = 0 ] && echo "STOP-SERVICES, ")$([ "$RESET" = 1 ] && echo "RESET, ")$([ "$SKIP_ETHERCAT_UNINSTALL" = 0 ] && echo "UNINSTALL-ETHERCAT, ")1-preflight, 2-deps, 3-host-config, 4-cluster, 5-seed-pull-secrets$([ "$SKIP_ETHERCAT_INSTALL" = 0 ] && echo ", INSTALL-ETHERCAT [gates 6]"), 6-gitops$([ "$SETUP_POSITRONIC" = 1 ] && echo ", 7-setup-positronic"), 8-validate
flags:  yes=$YES dry_run=$DRY_RUN keep_going=$KEEP_GOING skip_docker_stop=$SKIP_DOCKER_STOP skip_stop_services=$SKIP_STOP_SERVICES skip_ethercat_uninstall=$SKIP_ETHERCAT_UNINSTALL skip_ethercat_install=$SKIP_ETHERCAT_INSTALL reset=$RESET skip_deps=$SKIP_DEPS skip_host=$SKIP_HOST skip_cluster=$SKIP_CLUSTER skip_seed_pull_secrets=$SKIP_SEED_PULL_SECRETS skip_gitops=$SKIP_GITOPS skip_nvidia=$SKIP_NVIDIA skip_validate=$SKIP_VALIDATE
EOF

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
uninstall_ethercat      ; guard
preflight          ; guard
deps               ; guard
host_config        ; guard
cluster            ; guard
seed_pull_secrets  ; guard
install_dma_ethercat ; guard
gitops             ; guard
setup_positronic   ; guard
validate

summary
exit "$FAIL"
