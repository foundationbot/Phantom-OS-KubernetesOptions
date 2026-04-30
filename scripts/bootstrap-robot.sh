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
#   --skip-gitops      skip phase 5 (terraform apply)
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
#   5. gitops       cd terraform && terraform init && terraform apply
#                   (installs ArgoCD via the official Helm chart and
#                   applies gitops/root-app.yaml — the canonical path).
#                   Wait for phantomos-<robot> to reach Synced + Healthy.
#   6. setup-positronic (optional, --setup-positronic)
#                   Push positronic-control image to local registry,
#                   build phantom-models, and redeploy the pod.
#   7. validate     bash scripts/validate-local-registry.sh
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
SKIP_GITOPS=0
SKIP_NVIDIA=0
SKIP_VALIDATE=0
SETUP_POSITRONIC=0
POSITRONIC_IMAGE=""
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
    --skip-gitops)   SKIP_GITOPS=1; shift ;;
    --skip-nvidia)   SKIP_NVIDIA=1; shift ;;
    --skip-validate) SKIP_VALIDATE=1; shift ;;
    --setup-positronic)
                     SETUP_POSITRONIC=1; shift ;;
    --positronic-image)
                     POSITRONIC_IMAGE="${2:-}"; shift 2 ;;
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

[ -z "$ROBOT" ] && { usage >&2; printf '\nerror: --robot <name> is required\n' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || die "cd $REPO_ROOT"

if [ ! -d "$REPO_ROOT/manifests/robots/$ROBOT" ]; then
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

# ---- phase 5: gitops ----------------------------------------------------

gitops() {
  if [ "$SKIP_GITOPS" = 1 ]; then phase "phase 5: gitops  (skipped)"; return; fi
  phase "phase 5: gitops (terraform)"

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

# ---- phase 6: setup-positronic (optional) --------------------------------

setup_positronic() {
  if [ "$SETUP_POSITRONIC" = 0 ]; then return; fi
  phase "phase 6: setup-positronic"

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

# ---- phase 7: validate --------------------------------------------------

validate() {
  if [ "$SKIP_VALIDATE" = 1 ]; then phase "phase 7: validate  (skipped)"; return; fi
  phase "phase 7: validate"

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

cat <<EOF
bootstrap-robot.sh — robot=$ROBOT $([ "$DRY_RUN" = 1 ] && echo "(dry-run)")
repo: $REPO_ROOT
phases: $([ "$RESET" = 1 ] && echo "RESET, ")1-preflight, 2-deps, 3-host-config, 4-cluster, 5-gitops$([ "$SETUP_POSITRONIC" = 1 ] && echo ", 6-setup-positronic"), 7-validate
flags:  yes=$YES dry_run=$DRY_RUN keep_going=$KEEP_GOING reset=$RESET skip_deps=$SKIP_DEPS skip_host=$SKIP_HOST skip_cluster=$SKIP_CLUSTER skip_gitops=$SKIP_GITOPS skip_nvidia=$SKIP_NVIDIA skip_validate=$SKIP_VALIDATE
EOF

# When --reset is set, it has its own confirmation prompt with a
# detailed warning. Skip the generic confirmation.
if [ "$YES" = 0 ] && [ "$DRY_RUN" = 0 ] && [ "$RESET" = 0 ]; then
  printf '\nProceed? [y/N] '
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]] || { echo "aborted"; exit 1; }
fi

reset_cluster      ; guard
preflight          ; guard
deps               ; guard
host_config        ; guard
cluster            ; guard
gitops             ; guard
setup_positronic   ; guard
validate

summary
exit "$FAIL"
