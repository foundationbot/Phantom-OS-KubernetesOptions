#!/usr/bin/env bash
# bootstrap-robot.sh — bring a fresh machine to a working k0s + ArgoCD
# state for this fleet. Idempotent: re-running on a bootstrapped host
# detects existing config and skips destructive steps.
#
# Usage:
#   sudo bash scripts/bootstrap-robot.sh --robot <name> [flags]
#
# Required (first bringup only):
#   --robot <name>     Robot identifier; must match a directory under
#                      manifests/robots/ (e.g. ak-007, mk09). Also the
#                      Application name expected at
#                      gitops/apps/<name>/phantomos-<name>.yaml.
#                      On first bringup the value is persisted to
#                      /etc/phantomos/robot; subsequent runs (and other
#                      scripts like positronic.sh) read that file and
#                      no longer require --robot. The flag still wins
#                      when supplied — pass it again to retarget the
#                      host to a different overlay.
#
# Flags:
#   -y, --yes          skip confirmation prompts
#   --dry-run          print what each phase would do, change nothing
#   --keep-going       continue after failures (default: bail at first)
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
#   --skip-deps        skip phase 2 (apt installs + k0s/terraform binaries)
#   --skip-cluster     skip phase 3 (k0s install + systemd start)
#   --skip-host        skip phase 4 (host containerd/nvidia config)
#   --skip-seed-pull-secrets
#                      skip phase 5 (propagate dockerhub-creds Secret to
#                      argus / dma-video / nimbus namespaces)
#   --skip-gitops      skip phase 6 (terraform apply)
#   --ai-pc-url <url>  AI PC URL for the operator-ui pairing (e.g.
#                      http://100.124.202.97:5000). Required on FIRST
#                      bringup; on re-runs the value is read from
#                      /etc/phantomos/operator-ui-pairing.yaml. Pass
#                      this flag again to re-pair against a different
#                      AI PC.
#   --skip-pairing     skip phase 5.5 (operator-ui-pairing ConfigMap)
#   --host-config <path>
#                      copy the given file to /etc/phantomos/host-config.yaml.
#                      The host-config file is the single per-host
#                      source-of-truth (robot identity, aiPcUrl, image
#                      tag overrides). Bootstrap derives /etc/phantomos/
#                      operator-ui-pairing.yaml and the live Argo
#                      Application's spec.source.kustomize.images from
#                      it. If --host-config is omitted but the file
#                      already exists, it's used as-is. If it doesn't
#                      exist either, the script falls back to
#                      individual flags (--robot, --ai-pc-url) and
#                      skips image overrides.
#   --skip-image-overrides
#                      skip phase 6.7 (kustomize.images injection into
#                      the live Application)
#   --skip-dev-mounts  skip phase 6.8 (dev hostPath patches injection
#                      into the live Application). Use to suppress
#                      dev-mode mounts on production hosts that share
#                      a host-config.yaml with a dev block.
#   --skip-argocd-admin
#                      skip phase 6.5 (install argocd CLI + reset admin
#                      password to 1984)
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
#   5.5 pairing     create/refresh the operator-ui-pairing ConfigMap in
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
SKIP_DEPS=0
SKIP_HOST=0
SKIP_CLUSTER=0
SKIP_SEED_PULL_SECRETS=0
SKIP_PAIRING=0
SKIP_GITOPS=0
SKIP_IMAGE_OVERRIDES=0
SKIP_DEV_MOUNTS=0
AI_PC_URL=""
HOST_CONFIG_INPUT=""
SKIP_ARGOCD_ADMIN=0
SKIP_NVIDIA=0
SKIP_VALIDATE=0
SETUP_POSITRONIC=0
POSITRONIC_IMAGE=""
DOCKERHUB_SECRET_FILE=""
SEED_PULL_SECRETS_ONLY=0

# Namespaces that pull `foundationbot/*` images and therefore need the
# dockerhub-creds Secret. Kept in sync with REQUIREMENTS.md and with the
# `imagePullSecrets:` references in manifests/base/{argus,dma-video,nimbus}/.
PULL_SECRET_NAMESPACES=(argus dma-video nimbus)
PULL_SECRET_NAME="dockerhub-creds"

while [ $# -gt 0 ]; do
  case "$1" in
    --robot)         ROBOT="${2:-}"; shift 2 ;;
    -y|--yes)        YES=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --keep-going)    KEEP_GOING=1; shift ;;
    --reset)         RESET=1; shift ;;
    --skip-deps)     SKIP_DEPS=1; shift ;;
    --skip-host)     SKIP_HOST=1; shift ;;
    --skip-cluster)  SKIP_CLUSTER=1; shift ;;
    --skip-seed-pull-secrets)
                     SKIP_SEED_PULL_SECRETS=1; shift ;;
    --skip-pairing)  SKIP_PAIRING=1; shift ;;
    --ai-pc-url)     AI_PC_URL="${2:-}"; shift 2 ;;
    --host-config)   HOST_CONFIG_INPUT="${2:-}"; shift 2 ;;
    --skip-image-overrides)
                     SKIP_IMAGE_OVERRIDES=1; shift ;;
    --skip-dev-mounts)
                     SKIP_DEV_MOUNTS=1; shift ;;
    --skip-gitops)   SKIP_GITOPS=1; shift ;;
    --skip-argocd-admin)
                     SKIP_ARGOCD_ADMIN=1; shift ;;
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
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
phase() { printf '\n==> %s\n' "$1"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 2; }

# Bail early on FAIL unless --keep-going is set.
guard() { [ "$FAIL" -gt 0 ] && [ "$KEEP_GOING" = 0 ] && summary && exit "$FAIL"; }

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

# --seed-pull-secrets-only is namespace-level work — no robot context
# needed. --reset is a host-level purge that exits before any robot
# work. Otherwise we need to know which overlay to apply: prefer
# --robot, then /etc/phantomos/robot, then hostname.
if [ "$SEED_PULL_SECRETS_ONLY" = 0 ] && [ "$RESET" = 0 ]; then
  if ! ROBOT="$(resolve_robot "$ROBOT")"; then
    exit 2
  fi
fi

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

# ---- phase 5.5: pairing (operator-ui AI_PC_URL ConfigMap) ---------------

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

pairing() {
  if [ "$SKIP_PAIRING" = 1 ]; then phase "phase 5.5: pairing  (skipped)"; return; fi
  phase "phase 5.5: pairing (operator-ui AI_PC_URL ConfigMap)"

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
  # it already; create here defensively for --skip-seed-pull-secrets paths.
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

# ---- phase 6: gitops ----------------------------------------------------

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
RENDERED_APP_FILE="${RENDERED_APP_FILE:-/etc/phantomos/phantomos-app.yaml}"
DEFAULT_REPO_URL="${DEFAULT_REPO_URL:-https://github.com/foundationbot/Phantom-OS-KubernetesOptions.git}"
DEFAULT_TARGET_REVISION="${DEFAULT_TARGET_REVISION:-main}"

# Old design (now replaced): a `root` Application reconciled
# gitops/apps/<robot>/phantomos-<robot>.yaml files. On clusters that
# still have that structure live, we tear it down before applying the
# new direct Application — but without pruning workload resources.
_gitops_migrate_from_root_app() {
  local nsdone=0
  if "${KUBECTL[@]}" -n argocd get app root >/dev/null 2>&1; then
    info "found legacy 'root' Application — migrating away from app-of-apps"
    # Remove the finalizer so deleting root doesn't cascade-prune
    # children + their workloads. We will apply a fresh phantomos-$ROBOT
    # Application immediately afterwards, so workloads stay continuous.
    "${KUBECTL[@]}" -n argocd patch app root \
      --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    "${KUBECTL[@]}" -n argocd delete app root --wait=false >/dev/null 2>&1 || true
    nsdone=1
  fi
  # Drop any phantomos-<other-robot> Applications left from the
  # app-of-apps era. Keep the one matching this host.
  local apps app
  apps=$("${KUBECTL[@]}" -n argocd get app -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    case "$app" in
      "phantomos-$ROBOT") continue ;;
      phantomos-*)
        info "removing stale legacy Application: $app"
        "${KUBECTL[@]}" -n argocd patch app "$app" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        "${KUBECTL[@]}" -n argocd delete app "$app" --wait=false >/dev/null 2>&1 || true
        nsdone=1
        ;;
    esac
  done <<< "$apps"
  [ "$nsdone" = 1 ] && pass "legacy app-of-apps cleanup complete"
}

# Render the Application CR template into RENDERED_APP_FILE for this
# host. Substitutions are simple sed because the template values are
# repo-controlled (no shell injection surface from operator input).
_gitops_render_app() {
  local repo_url="${1:?repo_url required}"
  local target_rev="${2:?target_rev required}"

  if [ ! -r "$APP_TEMPLATE_FILE" ]; then
    fail "Application CR template not found: $APP_TEMPLATE_FILE"
    return 1
  fi

  mkdir -p "$(dirname "$RENDERED_APP_FILE")"
  sed \
    -e "s#{{ROBOT}}#$ROBOT#g" \
    -e "s#{{REPO_URL}}#$repo_url#g" \
    -e "s#{{TARGET_REVISION}}#$target_rev#g" \
    "$APP_TEMPLATE_FILE" > "$RENDERED_APP_FILE"
  chmod 0644 "$RENDERED_APP_FILE"
}

gitops() {
  if [ "$SKIP_GITOPS" = 1 ]; then phase "phase 6: gitops  (skipped)"; return; fi
  phase "phase 6: gitops (install argocd + apply per-host Application)"

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

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  cd $REPO_ROOT/terraform && terraform init && terraform apply -auto-approve -var=kubeconfig=$kc"
    info "DRY-RUN  render $APP_TEMPLATE_FILE -> $RENDERED_APP_FILE"
    info "DRY-RUN    ROBOT=$ROBOT  REPO_URL=$DEFAULT_REPO_URL  TARGET_REVISION=$target_rev"
    info "DRY-RUN  kubectl apply -f $RENDERED_APP_FILE"
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
  pass "terraform apply (argocd Helm install)"

  # Migrate from the old root-app + child-app topology if present.
  _gitops_migrate_from_root_app

  # Render and apply the per-host Application CR.
  if ! _gitops_render_app "$DEFAULT_REPO_URL" "$target_rev"; then
    return
  fi
  pass "rendered $RENDERED_APP_FILE  robot=$ROBOT  branch=$target_rev"

  if ! "${KUBECTL[@]}" apply -f "$RENDERED_APP_FILE" >/dev/null; then
    fail "kubectl apply -f $RENDERED_APP_FILE"
    return
  fi
  pass "phantomos-$ROBOT applied"

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

# ---- phase 6.7: kustomize image overrides (per-host) --------------------

# Inject the `images:` list from /etc/phantomos/host-config.yaml into the
# live phantomos-<robot> Argo Application's spec.source.kustomize.images.
# This is how per-host image tag overrides flow without polluting the
# git tree. The root app-of-apps has ignoreDifferences on this same path
# so the patch survives root reconciliation.
image_overrides() {
  if [ "$SKIP_IMAGE_OVERRIDES" = 1 ]; then phase "phase 6.7: image overrides  (skipped)"; return; fi
  phase "phase 6.7: image overrides (inject kustomize.images into Application)"

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

  local images_json
  if ! images_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-images-json 2>&1)"; then
    fail "host-config images parse error: $images_json"
    return
  fi
  if [ "$images_json" = "[]" ]; then
    skip "host-config has no images: block — nothing to inject"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  kubectl -n argocd patch app phantomos-$ROBOT --type=merge"
    info "DRY-RUN    set spec.source.kustomize.images = $images_json"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch Application"
    return
  fi

  if ! "${KUBECTL[@]}" -n argocd get app "phantomos-$ROBOT" >/dev/null 2>&1; then
    fail "Application phantomos-$ROBOT not present — gitops phase must run first"
    return
  fi

  # Argo Application's spec.source.kustomize is optional and may not
  # exist yet. JSON merge patch creates the parent objects on the fly.
  local patch
  patch=$(printf '{"spec":{"source":{"kustomize":{"images":%s}}}}' "$images_json")

  if "${KUBECTL[@]}" -n argocd patch app "phantomos-$ROBOT" \
       --type=merge -p "$patch" >/dev/null; then
    pass "patched phantomos-$ROBOT  kustomize.images: $images_json"
  else
    fail "kubectl patch app phantomos-$ROBOT failed"
    return
  fi

  # Force a sync so the new tags take effect immediately. selfHeal is
  # off by default on these Apps, so without this the operator has to
  # click sync in the UI or wait for the polling interval.
  if "${KUBECTL[@]}" -n argocd patch app "phantomos-$ROBOT" \
       --type=merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1; then
    pass "triggered sync of phantomos-$ROBOT"
  else
    info "could not trigger sync — argocd will pick up changes on next reconcile"
  fi
}

# ---- phase 6.8: dev hostPath mounts (per-host) --------------------------

# Inject the strategic-merge patch derived from
# /etc/phantomos/host-config.yaml's `devMode:` block into the live
# phantomos-<robot> Argo Application's spec.source.kustomize.patches.
# This is the dev-mode escape hatch — operators on dev machines can
# bind-mount the host's source tree, /data, /dev, etc. into pods so
# code changes are visible without rebuilding images.
#
# When devMode is unset OR --skip-dev-mounts is passed, the patches
# array is set to [] explicitly, which CLEARS any previously injected
# dev mounts. This means re-running bootstrap with devMode removed
# from host-config.yaml reverts the robot to a clean production
# topology.
dev_mounts() {
  if [ "$SKIP_DEV_MOUNTS" = 1 ]; then phase "phase 6.8: dev mounts  (skipped)"; return; fi
  phase "phase 6.8: dev mounts (inject kustomize.patches into Application)"

  # Same dry-run/canonical fallback as image_overrides.
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi

  local patches_json="[]"
  local stderr_capture
  if [ -r "$hc" ]; then
    stderr_capture="$(mktemp)"
    if ! patches_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-dev-patches-json 2>"$stderr_capture")"; then
      fail "host-config dev-patches parse error:"
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
  fi

  if [ "$patches_json" = "[]" ]; then
    info "no devMode in host-config — clearing any previously injected patches"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  kubectl -n argocd patch app phantomos-$ROBOT --type=merge"
    info "DRY-RUN    set spec.source.kustomize.patches = $patches_json"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch Application"
    return
  fi

  if ! "${KUBECTL[@]}" -n argocd get app "phantomos-$ROBOT" >/dev/null 2>&1; then
    fail "Application phantomos-$ROBOT not present — gitops phase must run first"
    return
  fi

  local patch
  patch=$(printf '{"spec":{"source":{"kustomize":{"patches":%s}}}}' "$patches_json")

  if "${KUBECTL[@]}" -n argocd patch app "phantomos-$ROBOT" \
       --type=merge -p "$patch" >/dev/null; then
    if [ "$patches_json" = "[]" ]; then
      pass "cleared dev-mode patches on phantomos-$ROBOT"
    else
      pass "patched phantomos-$ROBOT  kustomize.patches (dev mounts injected)"
    fi
  else
    fail "kubectl patch app phantomos-$ROBOT failed"
    return
  fi

  # Trigger a sync so the new Pod spec rolls out immediately.
  if "${KUBECTL[@]}" -n argocd patch app "phantomos-$ROBOT" \
       --type=merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1; then
    pass "triggered sync of phantomos-$ROBOT"
  else
    info "could not trigger sync — argocd will pick up changes on next reconcile"
  fi
}

# ---- phase 6.5: argocd admin (install CLI + reset password) -------------

# Installs the argocd CLI binary (latest release from GitHub) and resets
# the admin password to "1984" by writing a bcrypt hash into
# argocd-secret. Done as a script step rather than via `argocd account
# update-password` so we don't need a port-forward + login round-trip.
ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-1984}"

argocd_admin() {
  if [ "$SKIP_ARGOCD_ADMIN" = 1 ]; then phase "phase 6.5: argocd admin  (skipped)"; return; fi
  phase "phase 6.5: argocd admin (install CLI + set admin password)"

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

  # 2) reset admin password by patching argocd-secret
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  patch argocd-secret with bcrypt(admin password '$ARGOCD_ADMIN_PASSWORD')"
    return
  fi

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
    fail "htpasswd unavailable — install apache2-utils manually and re-run with --skip-* flags up to phase 6.5"
    return
  fi

  local hash mtime
  hash=$(htpasswd -nbBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
  mtime=$(date +%FT%T%Z)

  if "${KUBECTL[@]}" -n argocd patch secret argocd-secret --type merge \
       -p "{\"stringData\":{\"admin.password\":\"$hash\",\"admin.passwordMtime\":\"$mtime\"}}" >/dev/null; then
    pass "argocd admin password set to '$ARGOCD_ADMIN_PASSWORD'"
    # initial-admin-secret is no longer authoritative once admin.password
    # is rotated. Drop it so future operators don't try to use it.
    "${KUBECTL[@]}" -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null 2>&1 || true
  else
    fail "could not patch argocd-secret"
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
phases: $([ "$RESET" = 1 ] && echo "RESET (purge then exit)" || echo "1-preflight, 2-deps, 3-cluster, 4-host-config, 5-seed-pull-secrets, 5.5-pairing, 6-gitops, 6.5-argocd-admin, 6.7-image-overrides, 6.8-dev-mounts$([ "$SETUP_POSITRONIC" = 1 ] && echo ", 7-setup-positronic"), 8-validate")
flags:  yes=$YES dry_run=$DRY_RUN keep_going=$KEEP_GOING reset=$RESET skip_deps=$SKIP_DEPS skip_host=$SKIP_HOST skip_cluster=$SKIP_CLUSTER skip_seed_pull_secrets=$SKIP_SEED_PULL_SECRETS skip_pairing=$SKIP_PAIRING skip_gitops=$SKIP_GITOPS skip_argocd_admin=$SKIP_ARGOCD_ADMIN skip_image_overrides=$SKIP_IMAGE_OVERRIDES skip_dev_mounts=$SKIP_DEV_MOUNTS skip_nvidia=$SKIP_NVIDIA skip_validate=$SKIP_VALIDATE
host-config: $([ -r "$HOST_CONFIG_FILE" ] && echo "$HOST_CONFIG_FILE" || echo "<not present — using flag values, no image overrides>")
ai_pc_url: ${AI_PC_URL:-<from $PAIRING_FILE>}
EOF

# When --reset is set, it has its own confirmation prompt with a
# detailed warning. Skip the generic confirmation.
if [ "$YES" = 0 ] && [ "$DRY_RUN" = 0 ] && [ "$RESET" = 0 ]; then
  printf '\nProceed? [y/N] '
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]] || { echo "aborted"; exit 1; }
fi

reset_cluster      ; guard

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

preflight          ; guard

# Persist the resolved robot identity to /etc/phantomos/robot so future
# script runs on this host don't need --robot. Skipped in dry-run and
# in --seed-pull-secrets-only mode (no robot context).
if [ "$SEED_PULL_SECRETS_ONLY" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -n "${ROBOT:-}" ]; then
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
pairing            ; guard
gitops             ; guard
argocd_admin       ; guard
image_overrides    ; guard
dev_mounts         ; guard
setup_positronic   ; guard
validate

summary
exit "$FAIL"
