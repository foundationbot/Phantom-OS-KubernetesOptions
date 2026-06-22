#!/usr/bin/env bash
# bootstrap-robot.sh — bring a fresh machine to a working k0s + ArgoCD
# state for this fleet. Idempotent: re-running on a bootstrapped host
# detects existing config and skips destructive steps.
#
# Supported invocation roots:
#   - installed (.deb)  Run from /opt/Phantom-OS-KubernetesOptions/scripts/
#                       after `dpkg -i phantom-os-k8s-options*.deb`. The
#                       installed tree at /opt/... is the source tree.
#   - checkout          Run from any git checkout of this repo (e.g.
#                       ~/foundation/DMA/Phantom-OS-KubernetesOptions/
#                       scripts/bootstrap-robot.sh). Phase 10 (gitops)
#                       auto-symlinks /opt/Phantom-OS-KubernetesOptions
#                       -> $REPO_ROOT before terraform apply, so the
#                       argocd-repo-server hostPath mount resolves. If
#                       a real /opt/Phantom-OS-KubernetesOptions dir
#                       already exists (foreign .deb), bootstrap refuses
#                       and tells the operator to teardown.sh first —
#                       dpkg-managed files are not clobbered.
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
#                        (holds AI_PC_HOST + CONTROL_PC_HOST; reserved for any
#                        future per-host operator-ui env)
#   --locomotion-config  render+apply the phantom-locomotion-config
#                        ConfigMap (LOCOMOTION_POLICY, sourced from
#                        host-config phantomLocomotion.policy field).
#   --sonic-config       render+apply the phantom-sonic-config ConfigMap
#                        (ROS domain, walking policy, encoder mode, ZMQ/web
#                        ports, ramp; sourced from host-config phantomSonic).
#   --psi-config         render+apply the phantom-psi-config ConfigMap
#                        (Ψ₀ run dir/ckpt/camera/queues/instruction, ROS
#                        domain, bridge rate, loco enable flags, walking
#                        ONNX; sourced from host-config phantomPsi).
#   --ecat-interface     resolve the EtherCAT NIC adapter and rename it
#                        to cpuIsolation.nic.iface via persistent udev
#                        rules. Driven by cpuIsolation.nic.selector
#                        (mac/pci/driver+index); falls back to the
#                        vendored interactive picker on a TTY.
#                        See docs/internal/cpu-isolation.md.
#   --cpu-isolation      activate cpuset partitions, install cpusets.service,
#                        write systemd CPUAffinity drop-in, optionally pin
#                        EtherCAT NIC IRQs and migrate kernel cmdline. Reads
#                        host-config.yaml's cpuIsolation: block; no-op when
#                        cpuIsolation.enabled is unset/false.
#                        See docs/internal/cpu-isolation.md.
#   --log-management     install journald + logrotate drop-ins from
#                        host-config.yaml's logManagement: block. Caps
#                        journald disk usage and forces rsyslog logrotate
#                        to honour a maxsize. Sane defaults are applied
#                        when the block is absent (opt-out via
#                        logManagement.enabled: false). See docs/operations.md.
#   --gitops             terraform apply (argocd Helm) + render+apply
#                        the per-host phantomos-<robot> Application
#   --argocd-admin       install argocd CLI; prompt and set admin
#                        password (default '1984' on empty input)
#   --load-image-tars    load + push prebuilt phantom-models /
#                        phantom-policies image tarballs into the
#                        in-cluster localhost:5443 registry, then wire
#                        the loaded tag into host-config.yaml's images:
#                        block. Provide the tarball paths via
#                        --phantom-models-tar / --phantom-policies-tar
#                        (on an interactive full bootstrap, prompts for
#                        any path not given). Runs between gitops and
#                        image-overrides so the unchanged image-overrides
#                        phase injects the new tag. See operations.md §3.13.
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
#   --skip-operator-ui-config skip the phase 6 operator-ui-config setup
#                        (operator-ui-pairing CM + vr-web TLS cert)
#   --skip-ecat-interface skip the phase 9 ecat-interface setup
#   --skip-cpu-isolation skip the phase 10 cpu-isolation setup
#   --skip-log-management skip the phase 11 log-management setup
#   --skip-validate      skip the final validate-local-registry.sh run
#   --no-tailscale       ignore Tailscale when resolving the cluster API
#                        address; bind spec.api.address to the
#                        default-gateway IPv4 even if tailscaled is up
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
#   --phantom-models-tar <path>
#                      path to a prebuilt phantom-models image tarball
#                      (docker save output: .tar / .tar.gz / .tgz /
#                      .tar.zst). Consumed by the load-image-tars phase:
#                      loaded, pushed to localhost:5443, and wired into
#                      host-config.yaml's images: block.
#   --phantom-policies-tar <path>
#                      path to a prebuilt phantom-policies image tarball
#                      (same formats as --phantom-models-tar). Consumed
#                      by the load-image-tars phase.
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
#   sudo bash scripts/bootstrap-robot.sh --ecat-interface --cpu-isolation
#                                                              # rerun realtime setup only
#   sudo bash scripts/bootstrap-robot.sh --skip-cpu-isolation --skip-ecat-interface
#                                                              # full bootstrap, skip RT setup
#
#   -h, --help         this help
#
# Phases (bootstrap runs all of them in order; --<phase> selects one):
#   pre-phases (run before phase 1; default-on, opt out via --skip-*):
#     purge workload pods        (--skip-purge-pods)
#     stop docker containers     (--skip-docker-stop)
#     stop system services       (--skip-stop-services)
#     uninstall dma-ethercat     (--skip-ethercat-uninstall)
#                                Tears down dma-ethercat.service and
#                                runs the .deb's dma-ethercat-uninstall
#                                script, which WIPES /etc/dma/ — operator
#                                files placed under /etc/dma/ (e.g. a
#                                customized JSON config) are removed.
#                                Pass --skip-ethercat-uninstall to keep
#                                the existing /etc/dma/ tree.
#
#    1. preflight    OS / arch / kernel / disk / sudo / port collisions
#    2. deps         apt: docker.io, skopeo, python3, curl, jq, git,
#                    pciutils, unzip; k0s binary; terraform binary
#    3. cluster      k0s install controller --single --enable-worker;
#                    systemctl enable --now k0scontroller; wait Ready;
#                    write /root/.kube/config from `k0s kubeconfig admin`
#                    (so kubectl + terraform have a config to read).
#                    Runs BEFORE host config because the host-config scripts
#                    edit /etc/k0s/containerd.toml, which only exists after
#                    k0s has started at least once.
#    4. host config  configure-k0s-containerd-mirror.sh +
#                    configure-k0s-nvidia-runtime.sh (if a GPU is detected
#                    via lspci or /dev/nvidia0). Restarts k0s; waits for
#                    node Ready before returning so later phases don't race.
#    5. seed pull secrets
#                    ensure `dockerhub-creds` (kubernetes.io/dockerconfigjson)
#                    exists in `argus`, `dma-video`, `nimbus`, `phantom` so
#                    private foundationbot/* images can be pulled. Source
#                    order: --dockerhub-secret-file, then ~/.docker/config.json
#                    (default), then existing Secret in the `phantom`
#                    namespace, then no-op if already present in every
#                    target namespace. Idempotent.
#    6. operator-ui-config
#                    create/refresh the operator-ui-pairing ConfigMap in
#                    the `argus` namespace from
#                    /etc/phantomos/operator-ui-pairing.yaml. Holds two
#                    keys: AI_PC_HOST (the paired AI PC) and
#                    CONTROL_PC_HOST (the robot's own reachable address,
#                    resolved Tailscale-first like spec.api.address;
#                    override with CONTROL_PC_HOST_OVERRIDE=<ip>).
#                    operator-ui composes AI_PC_URL and CONTROL_PC_URL
#                    from those via configMapKeyRef. On first bringup
#                    --ai-pc-url is required; subsequent runs without
#                    the flag preserve AI_PC_HOST from the local file
#                    and re-resolve CONTROL_PC_HOST fresh. Rolls out
#                    operator-ui to pick up either change.
#    7. locomotion-config
#                    render+apply the phantom-locomotion-config ConfigMap
#                    from host-config's phantomLocomotion block (mode /
#                    policy / diagnostic tunables). Rolls the
#                    phantom-locomotion DaemonSet if present.
#    8. sonic-config  render+apply the phantom-sonic-config ConfigMap from
#                    host-config's phantomSonic block (ROS domain, walking
#                    policy, encoder mode, ZMQ/web ports, ramp). Rolls the
#                    phantom-sonic DaemonSet if present.
#    8b. psi-config   render+apply the phantom-psi-config ConfigMap from
#                    host-config's phantomPsi block (Ψ₀ run dir/ckpt/camera/
#                    queues/instruction, ROS domain, bridge rate, loco enable
#                    flags, walking ONNX). Rolls the phantom-psi DaemonSet if
#                    present.
#    9. ecat-interface (gates phase 10)
#                    resolve the EtherCAT NIC adapter and rename it to
#                    cpuIsolation.nic.iface via a persistent udev rule
#                    (/etc/udev/rules.d/70-ecat.rules). Driven by
#                    cpuIsolation.nic.selector (mac/pci/driver+index) in
#                    host-config.yaml; falls back to the vendored
#                    interactive picker on a TTY. Idempotent — fast-paths
#                    when `ip link show <iface>` already succeeds.
#                    See docs/internal/cpu-isolation.md.
#   10. cpu-isolation (gates phase 12)
#                    activate cgroup v2 cpuset partitions; install
#                    cpusets.service so they reactivate at boot
#                    (ordered Before docker / user@ / k0scontroller /
#                    k0sworker); write systemd CPUAffinity drop-in;
#                    pin EtherCAT NIC IRQs to cpuIsolation.nic.irqCore;
#                    optionally migrate kernel cmdline (--migrateCmdline).
#                    Default-on: missing cpuIsolation: block prompts on
#                    a TTY and persists answers. enabled: false skips.
#                    See docs/internal/cpu-isolation.md.
#   11. log-management
#                    install journald + logrotate drop-ins capping disk
#                    use (default-on; --skip-log-management to opt out).
#   12. install dma-ethercat (gates phase 13)
#                    Default-on. Pass --skip-ethercat-install to bypass.
#                    Renders the bootstrap-managed installer Job from
#                    the foundationbot/dma-ethercat tag in host-config
#                    images:, applies, dpkg-i the .deb extracted to the
#                    host, then writes DMA_CONFIG / INTERFACE /
#                    DMA_CPU_AFFINITY / DMA_RT_CPU into
#                    /etc/dma/dma-ethercat.env (preserving operator
#                    edits) and `systemctl enable --now
#                    dma-ethercat.service`. ANY failure halts bootstrap.
#   13. gitops       cd terraform && terraform init && terraform apply
#                    (installs ArgoCD via the official Helm chart). Then
#                    render per-host Application CRs (one per enabled
#                    stack — phantomos-<robot>-core, phantomos-<robot>-operator)
#                    from host-config-templates/_template/phantomos-app.yaml.tpl
#                    into /etc/phantomos/phantomos-app-<stack>.yaml and
#                    kubectl-apply each. Migrates from any pre-existing
#                    root-app + child-app topology without pruning workload
#                    state.
#   14. argocd admin install argocd CLI (latest release) under
#                    /usr/local/bin/argocd and reset the admin password
#                    to "1984" by patching argocd-secret with a bcrypt
#                    hash. Idempotent (always rewrites the hash). Also
#                    removes argocd-initial-admin-secret since it is no
#                    longer authoritative.
#   14b. load-image-tars (optional; runs between gitops and image-overrides)
#                    wait for the k0s-registry Deployment to become
#                    Available, then for each provided tarball
#                    (--phantom-models-tar / --phantom-policies-tar, or,
#                    on an interactive full bootstrap, prompted) call
#                    scripts/load-image-tars.sh to load + push the
#                    localhost:5443/* tag and host-config.py set-image to
#                    wire that tag into host-config.yaml's images: block.
#                    Soft-skips if neither tarball is provided or the
#                    registry never becomes Available. The following
#                    image-overrides phase injects the new tag live.
#   15. image overrides
#                    inject host-config.yaml's images: list into the live
#                    per-stack Argo Applications via
#                    spec.source.kustomize.images. Filtered per stack —
#                    each Application only sees images its manifests
#                    actually reference. foundationbot/dma-ethercat is
#                    NOT routed (consumed directly by phase 9).
#   16. deployments  inject host-config.yaml's deployments: block as
#                    strategic-merge patches into the live per-stack
#                    Applications via spec.source.kustomize.patches.
#                    Currently routes positronic-control + phantomos-api-server
#                    mounts onto the core stack. Alias: --dev-mounts.
#   17. setup-positronic (optional, --setup-positronic)
#                    push positronic-control image to local registry,
#                    build phantom-models, and redeploy the pod.
#   18. validate     bash scripts/validate-local-registry.sh
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
AI_PC_URL=""
HOST_CONFIG_INPUT=""
SETUP_POSITRONIC=0
POSITRONIC_IMAGE=""
PHANTOM_MODELS_TAR=""
PHANTOM_POLICIES_TAR=""
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
SKIP_LOCOMOTION_CONFIG=0
SKIP_SONIC_CONFIG=0
SKIP_PSI_CONFIG=0
SKIP_GITOPS=0
SKIP_ARGOCD_ADMIN=0
SKIP_LOAD_IMAGE_TARS=0
SKIP_IMAGE_OVERRIDES=0
SKIP_DEV_MOUNTS=0
SKIP_VALIDATE=0
SKIP_NVIDIA=0
NO_TAILSCALE=0

# Pre-phase + dma-ethercat skip flags (default-on phases, hence the
# inverted polarity from the per-phase opt-in flags above).
SKIP_PURGE_PODS=0
SKIP_DOCKER_STOP=0
SKIP_STOP_SERVICES=0
SKIP_ETHERCAT_UNINSTALL=0
SKIP_ECAT_INTERFACE=0
SKIP_CPU_ISOLATION=0
SKIP_LOG_MANAGEMENT=0
# dma-ethercat install runs by default. Combined with the default-on
# uninstall pre-phase, a routine bootstrap re-run gives you a clean
# reinstall of the realtime stack. Pass --skip-ethercat-install to
# bypass (e.g. when iterating on a non-ethercat phase and you want to
# preserve the running realtime stack).
SKIP_INSTALL_DMA_ETHERCAT=0
SELECTED_PHASES=()

# Namespaces whose pods are deleted by the purge-workload-pods pre-phase.
# These are the namespaces the bootstrap script itself creates / seeds.
# Kept in sync with PULL_SECRET_NAMESPACES + the argocd namespace owned
# by the gitops phase's terraform/helm install.
WORKLOAD_NAMESPACES=(argocd argus dma-video nimbus phantom positronic psi)

# Namespaces that pull `foundationbot/*` images and therefore need the
# dockerhub-creds Secret. Kept in sync with REQUIREMENTS.md and with the
# `imagePullSecrets:` references in manifests/base/{argus,dma-video,nimbus}/.
PULL_SECRET_NAMESPACES=(argus dma-video nimbus phantom positronic psi)
PULL_SECRET_NAME="dockerhub-creds"

# Host-systemd services to stop + disable before bringing up the cluster.
# Each entry is an ERE substring matched case-insensitively against
# `systemctl list-unit-files --state=enabled` output. Append to extend.
#   - api.*server   — host-systemd copy of phantomos-api-server (replaced by pod)
#   - dma.*ethercat — replaced by phase 12 .deb install
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
    --locomotion-config) SELECTED_PHASES+=(locomotion-config); shift ;;
    --sonic-config)      SELECTED_PHASES+=(sonic-config); shift ;;
    --psi-config)        SELECTED_PHASES+=(psi-config); shift ;;
    --ecat-interface)    SELECTED_PHASES+=(ecat-interface); shift ;;
    --cpu-isolation)     SELECTED_PHASES+=(cpu-isolation); shift ;;
    --log-management)    SELECTED_PHASES+=(log-management); shift ;;
    --gitops)            SELECTED_PHASES+=(gitops); shift ;;
    --argocd-admin)      SELECTED_PHASES+=(argocd-admin); shift ;;
    --load-image-tars)   SELECTED_PHASES+=(load-image-tars); shift ;;
    --image-overrides)   SELECTED_PHASES+=(image-overrides); shift ;;
    --deployments|--dev-mounts)
                         SELECTED_PHASES+=(dev-mounts); shift ;;
    --install-dma-ethercat)
                         SELECTED_PHASES+=(install-dma-ethercat); shift ;;
    --validate)          SELECTED_PHASES+=(validate); shift ;;

    # Targeted overrides that compose with both modes.
    --skip-nvidia)       SKIP_NVIDIA=1; shift ;;
    --skip-validate)     SKIP_VALIDATE=1; shift ;;
    --no-tailscale)      NO_TAILSCALE=1; shift ;;
    --skip-purge-pods)   SKIP_PURGE_PODS=1; shift ;;
    --skip-docker-stop)  SKIP_DOCKER_STOP=1; shift ;;
    --skip-stop-services) SKIP_STOP_SERVICES=1; shift ;;
    --skip-ethercat-uninstall)
                         SKIP_ETHERCAT_UNINSTALL=1; shift ;;
    --uninstall-ethercat)
                         # Explicitly run the dma-ethercat uninstaller. Wipes
                         # /etc/dma/ — operator-placed config files there
                         # WILL be removed. Use only when you actually want
                         # a clean reinstall.
                         SKIP_ETHERCAT_UNINSTALL=0; shift ;;
    --skip-ecat-interface)
                         SKIP_ECAT_INTERFACE=1; shift ;;
    --skip-cpu-isolation)
                         SKIP_CPU_ISOLATION=1; shift ;;
    --skip-log-management)
                         SKIP_LOG_MANAGEMENT=1; shift ;;
    --skip-operator-ui-config)
                         SKIP_OPERATOR_UI_CONFIG=1; shift ;;
    --skip-ethercat-install)
                         SKIP_INSTALL_DMA_ETHERCAT=1; shift ;;
    --with-ethercat-install|--enable-ethercat-install)
                         # Opt into ethercat install in a full bootstrap
                         # without entering selected-phases mode (which
                         # --install-dma-ethercat does). Companion to the
                         # default-off SKIP_INSTALL_DMA_ETHERCAT.
                         SKIP_INSTALL_DMA_ETHERCAT=0; shift ;;

    # Inputs.
    --robot)             ROBOT="${2:-}"; shift 2 ;;
    --ai-pc-url)         AI_PC_URL="${2:-}"; shift 2 ;;
    --host-config)       HOST_CONFIG_INPUT="${2:-}"; shift 2 ;;
    --dockerhub-secret-file)
                         DOCKERHUB_SECRET_FILE="${2:-}"; shift 2 ;;
    --setup-positronic)  SETUP_POSITRONIC=1; shift ;;
    --positronic-image)  POSITRONIC_IMAGE="${2:-}"; shift 2 ;;
    --phantom-models-tar)
                         PHANTOM_MODELS_TAR="${2:-}"; shift 2 ;;
    --phantom-policies-tar)
                         PHANTOM_POLICIES_TAR="${2:-}"; shift 2 ;;

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

# CPU isolation (cpuset partitions, NIC IRQ pinning, kernel cmdline
# migration). Helper wraps the vendored scripts/cpusets/manage_cpusets.sh
# and renders /etc/cpusets.conf from host-config.yaml.
# shellcheck source=scripts/lib/cpusets.sh
. "$SCRIPT_DIR/lib/cpusets.sh"

# EtherCAT NIC setup library — phase 9 sources these helpers and drives
# the workflow directly rather than shelling out to
# setup_ethercat_interface.sh (which kept its own decision tree). Lets
# bootstrap make the idempotency call (rule already present + iface
# already named -> no-op) BEFORE invoking the write path.
# shellcheck source=scripts/cpusets/lib/nic_setup.sh
. "$SCRIPT_DIR/cpusets/lib/nic_setup.sh"

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
  SKIP_LOCOMOTION_CONFIG=1
  SKIP_SONIC_CONFIG=1
  SKIP_PSI_CONFIG=1
  SKIP_ECAT_INTERFACE=1
  SKIP_CPU_ISOLATION=1
  SKIP_LOG_MANAGEMENT=1
  SKIP_GITOPS=1
  SKIP_ARGOCD_ADMIN=1
  SKIP_LOAD_IMAGE_TARS=1
  SKIP_IMAGE_OVERRIDES=1
  SKIP_DEV_MOUNTS=1
  SKIP_VALIDATE=1
  SKIP_INSTALL_DMA_ETHERCAT=1
  # Pre-phases are off by default in selected-phases mode: the
  # operator asked for ONE thing and shouldn't get a fleet-wide pod
  # purge / docker stop / service halt as a side effect. Full
  # bootstrap (no --<phase> flags) still runs them by default.
  SKIP_PURGE_PODS=1
  SKIP_DOCKER_STOP=1
  SKIP_STOP_SERVICES=1
  SKIP_ETHERCAT_UNINSTALL=1
  for _p in "${SELECTED_PHASES[@]}"; do
    case "$_p" in
      deps)              SKIP_DEPS=0 ;;
      cluster)           SKIP_CLUSTER=0 ;;
      host)              SKIP_HOST=0 ;;
      seed-pull-secrets) SKIP_SEED_PULL_SECRETS=0 ;;
      operator-ui-config) SKIP_OPERATOR_UI_CONFIG=0 ;;
      locomotion-config) SKIP_LOCOMOTION_CONFIG=0 ;;
      sonic-config)      SKIP_SONIC_CONFIG=0 ;;
      psi-config)        SKIP_PSI_CONFIG=0 ;;
      ecat-interface)    SKIP_ECAT_INTERFACE=0 ;;
      cpu-isolation)     SKIP_CPU_ISOLATION=0 ;;
      log-management)    SKIP_LOG_MANAGEMENT=0 ;;
      gitops)            SKIP_GITOPS=0 ;;
      argocd-admin)      SKIP_ARGOCD_ADMIN=0 ;;
      load-image-tars)   SKIP_LOAD_IMAGE_TARS=0 ;;
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
      deps|seed-pull-secrets|argocd-admin|validate|install-dma-ethercat|cpu-isolation|log-management|ecat-interface|load-image-tars) ;;
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

# ---- pre-phase: purge workload pods (default; --skip-purge-pods) ------
#
# Delete every pod in the namespaces this script is responsible for
# creating (WORKLOAD_NAMESPACES). Lets a re-bootstrap start from a
# clean workload state without requiring the heavier --reset path.
# Skips gracefully when:
#   - kubectl is not yet on PATH (fresh machine, nothing to purge)
#   - the API server is unreachable (cluster down or not installed)
#   - a target namespace does not exist
# Pods are deleted with --force --grace-period=0 --wait=false so the
# pre-phase does not block on finalizers; the kubelet reaps the
# containers once the API server records the deletion.
purge_workload_pods() {
  if [ "$SKIP_PURGE_PODS" = 1 ]; then
    phase "pre-phase: purge workload pods  (skipped — --skip-purge-pods)"
    return
  fi
  phase "pre-phase: purge workload pods"

  if [ "${#KUBECTL[@]}" -eq 0 ]; then
    skip "kubectl not installed yet — nothing to purge"
    return
  fi
  if ! "${KUBECTL[@]}" --request-timeout=5s get ns >/dev/null 2>&1; then
    skip "cluster API not reachable — nothing to purge"
    return
  fi

  local ns count
  for ns in "${WORKLOAD_NAMESPACES[@]}"; do
    if ! "${KUBECTL[@]}" get ns "$ns" >/dev/null 2>&1; then
      skip "ns/$ns absent"
      continue
    fi
    count=$("${KUBECTL[@]}" -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
      skip "ns/$ns has no pods"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      note "DRY-RUN: kubectl -n $ns delete pods --all --force --grace-period=0 --wait=false  ($count pod(s))"
      continue
    fi
    if "${KUBECTL[@]}" -n "$ns" delete pods --all --force --grace-period=0 --wait=false >/dev/null 2>&1; then
      pass "purged $count pod(s) in ns/$ns"
    else
      fail "delete pods in ns/$ns"
    fi
  done
}

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

# ---- pre-phase: uninstall dma-ethercat (DEFAULT ON; --skip-ethercat-uninstall) -

# Tear down the dma-ethercat realtime control service so phase 12's
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

# ---- pre-phase: uninstall dma-ethercat (DEFAULT ON; --skip-ethercat-uninstall) -

# Tear down the dma-ethercat realtime control service. DEFAULT ON —
# routine bootstrap re-runs tear down the realtime stack so a fresh
# phase 12 install (when --with-ethercat-install is passed) lands on a
# clean slate. WARNING: the .deb's dma-ethercat-uninstall script wipes
# /etc/dma/, removing operator-placed config JSONs. If your robot has
# hand-edited config you don't want to lose, pass --skip-ethercat-uninstall
# to keep the existing /etc/dma/ tree untouched (phase 12 still refreshes
# the env file to point DMA_CONFIG at whatever host-config
# dmaEthercat.configPath specifies). Designed to run AFTER purge_docker
# and reset_cluster so the pods that talk to ethercat are already gone
# — stopping the service while pods are still pinging its socket can
# leave the kernel module in a wedged state.
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

  # 3. run the uninstaller (optional — older installs may not ship one)
  # If it's missing, stop+disable above is enough to neutralize the
  # service for the duration of this bootstrap; the unit file stays on
  # disk but is inert until something re-enables it.
  if [ ! -e "$uninstaller" ]; then
    skip "$uninstaller not present — relying on stop+disable above"
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

  apt_pkgs=(skopeo python3 curl jq git pciutils unzip)

  # docker.io vs docker-ce: Ubuntu's `docker.io` and Docker Inc.'s
  # `docker-ce` (which pulls `containerd.io`) are mutually exclusive —
  # apt refuses to coinstall them because their containerd packages
  # conflict. The bootstrap only needs the `docker` binary (for
  # prime-registry-cache.sh's pull/tag/push), and either provider
  # gives us that. So: detect docker by binary, not package name.
  if command -v docker >/dev/null 2>&1; then
    skip "docker already installed ($(command -v docker)) — not adding docker.io"
  else
    apt_pkgs+=(docker.io)
  fi

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
    else
      # apt-get install -y's exit code conflates two failure modes:
      #   (a) the package we want couldn't be installed
      #   (b) some unrelated package in the same dpkg transaction had a
      #       postinst failure
      # Common (b) case: a fresh apt run also pulls in linux-headers
      # updates, whose postinst triggers a DKMS rebuild of the NVIDIA
      # module, which refuses because the module is already installed.
      # apt-get exits non-zero, but the package we asked for is installed
      # fine — bootstrap shouldn't halt on that. So we ignore apt's exit
      # code and check each requested package's actual installed state
      # via dpkg-query. Pass for what landed; fail only for what didn't.
      apt_log=$(mktemp)
      apt-get update -qq >>"$apt_log" 2>&1 || true
      apt-get install -y "${to_install[@]}" >>"$apt_log" 2>&1
      apt_rc=$?

      really_failed=()
      for p in "${to_install[@]}"; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null \
             | grep -q 'install ok installed'; then
          pass "$p installed"
        else
          really_failed+=("$p")
        fi
      done

      if [ "${#really_failed[@]}" -gt 0 ]; then
        fail "apt install failed for: ${really_failed[*]}"
        sed 's/^/    apt: /' "$apt_log" >&2
      elif [ "$apt_rc" != 0 ]; then
        # apt-get returned non-zero but every requested package is in
        # 'install ok installed' state. Surface as informational, not a
        # hard failure — almost always an unrelated postinst issue
        # (e.g. nvidia DKMS conflict during a linux-headers upgrade).
        info "apt-get exit=$apt_rc but all requested packages installed —"
        info "  unrelated postinst issue, run 'sudo dpkg --audit' to inspect"
      fi
      rm -f "$apt_log"
    fi
  fi

  # k0s — PINNED for deterministic bringup. get.k0s.sh installs the
  # LATEST release by default, which silently jumped fresh robots from
  # containerd 1.7.x (k0s 1.35.x) to containerd 2.x (k0s 1.36+). The two
  # use different containerd config formats, so the unpinned jump broke
  # the containerd drop-ins (configure-k0s-*). Pin so every fresh robot
  # lands on the same validated version; bump deliberately with
  # K0S_VERSION=v1.x.y+k0s.0 (and re-test the containerd config format).
  K0S_VERSION="${K0S_VERSION:-v1.35.4+k0s.0}"
  if command -v k0s >/dev/null 2>&1; then
    installed_k0s="$(k0s version 2>/dev/null | head -1)"
    if [ "$installed_k0s" = "$K0S_VERSION" ]; then
      skip "k0s already in PATH ($installed_k0s, matches pin)"
    else
      skip "k0s already in PATH ($installed_k0s) — differs from pin $K0S_VERSION; not reinstalling ('k0s reset' then re-run to change)"
    fi
  elif [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  curl -sSLf https://get.k0s.sh | K0S_VERSION=$K0S_VERSION sh"
  elif curl -sSLf https://get.k0s.sh | K0S_VERSION="$K0S_VERSION" sh >/dev/null 2>&1; then
    pass "k0s installed ($K0S_VERSION)"
  else
    fail "k0s install failed (curl https://get.k0s.sh | K0S_VERSION=$K0S_VERSION sh)"
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

  # Always run — the script is internally idempotent (hosts.toml insert
  # is no-op when already present, daemon.json merge is no-op when the
  # entry exists). A previous skip-on-hosts.toml-only check could leave
  # /etc/docker/daemon.json without the insecure-registries entry on
  # hosts where containerd was set up but docker wasn't.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  bash $REPO_ROOT/scripts/configure-k0s-containerd-mirror.sh"
  elif bash "$REPO_ROOT/scripts/configure-k0s-containerd-mirror.sh"; then
    pass "containerd mirror configured (idempotent re-run)"
  else
    fail "configure-k0s-containerd-mirror.sh"
  fi

  # OAK USB power — install udev rule disabling autosuspend for VID
  # 03e7 so libusb's claim+rebind during DepthAI firmware boot doesn't
  # race the kernel powering the device down. Idempotent; harmless on
  # hosts without OAK cameras (rule just never fires). Doesn't touch
  # k0s, so it runs above the post-config Ready wait below.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  bash $REPO_ROOT/scripts/configure-usb-power.sh"
  elif bash "$REPO_ROOT/scripts/configure-usb-power.sh"; then
    pass "OAK USB autosuspend disabled (udev rule installed)"
  else
    fail "configure-usb-power.sh"
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

# Tailscale used to be a hard requirement for the cluster phase. It now
# softly informs whether Tailscale is present + ready; resolution and
# fallback are handled by _resolve_api_address. Always returns 0 so the
# caller can proceed regardless. The info messages still surface the
# tailscale state so an operator who EXPECTED Tailscale to be up sees
# the diagnostic.
_require_tailscale() {
  if [ "$NO_TAILSCALE" = 1 ]; then
    info "tailscale opt-out (--no-tailscale); cluster API will bind to default-gateway IP"
    return 0
  fi
  if ! command -v tailscale >/dev/null 2>&1; then
    info "tailscale not installed; cluster API will bind to default-gateway IP"
    return 0
  fi
  local state
  state=$(tailscale status --json 2>/dev/null | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("BackendState","Unknown"))' 2>/dev/null || echo Unknown)
  if [ "$state" != "Running" ]; then
    info "tailscale present but not running (BackendState=$state); will fall back to default-gateway IP"
    return 0
  fi
  local ip
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  if [ -z "$ip" ]; then
    info "tailscale running but no IPv4 yet; will poll briefly then fall back to default-gateway IP"
    return 0
  fi
  info "tailscale up (IPv4=$ip); cluster API will bind to it"
  return 0
}

# LAN fallback when Tailscale isn't available. Picks the IPv4 address
# of the interface that owns the default route — same logic the
# configure-host wizard uses for the AI PC URL. Echoes the IP, or
# returns 1 if no default route / no IPv4 (which would also break
# everything else, so the caller can fail loudly there).
_resolve_default_gateway_ip() {
  command -v ip >/dev/null 2>&1 || return 1
  local iface ip4
  iface=$(ip -4 route show default 2>/dev/null \
            | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [ -n "$iface" ] || return 1
  ip4=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
          | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$ip4" ] || return 1
  printf '%s\n' "$ip4"
}

# Resolve a stable IPv4 for spec.api.address. Tailscale-first (so the
# Tailscale mesh stays the canonical address when it's available),
# default-gateway IP as fallback (so robots on plain LAN/static-IP
# setups bootstrap fine without Tailscale). Polls for up to
# API_ADDRESS_WAIT_SECS so the cluster phase can run during a cold
# boot before tailscaled has finished associating; falls back if the
# wait expires.
_resolve_api_address() {
  local wait_secs=${API_ADDRESS_WAIT_SECS:-60}
  local elapsed=0

  # Operator opted out of Tailscale (--no-tailscale) — go straight to
  # LAN fallback regardless of whether tailscaled is up.
  if [ "$NO_TAILSCALE" = 1 ]; then
    _resolve_default_gateway_ip || return 1
    return 0
  fi

  # No tailscale CLI at all — go straight to LAN fallback.
  if ! command -v tailscale >/dev/null 2>&1; then
    _resolve_default_gateway_ip || return 1
    return 0
  fi

  # Tailscale installed but not Running — don't waste 60s polling.
  local state
  state=$(tailscale status --json 2>/dev/null | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("BackendState","Unknown"))' 2>/dev/null || echo Unknown)
  if [ "$state" != "Running" ]; then
    _resolve_default_gateway_ip || return 1
    return 0
  fi

  # Tailscale Running; poll for an IPv4 to surface.
  while [ "$elapsed" -lt "$wait_secs" ]; do
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
    if [ -n "$ts_ip" ]; then
      printf '%s\n' "$ts_ip"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  # Backend was Running but no IP ever came up. Fall back rather than
  # block the bootstrap on a partly-broken Tailscale install.
  _resolve_default_gateway_ip || return 1
  return 0
}

# Detect the install-time race: kube-apiserver running with the '1.1.1.1'
# sentinel. Pods can't reach the API via the cluster service IP because
# kube-proxy DNATs to advertise-address.
_apiserver_advertises_sentinel() {
  pgrep -af kube-apiserver 2>/dev/null \
    | grep -q -- "--advertise-address=1\.1\.1\.1"
}

# Heal an already-installed cluster whose advertise-address is the
# sentinel. Writes /etc/k0s/k0s.yaml + a systemd drop-in pointing
# k0scontroller's ExecStart at it, then restarts k0scontroller. Idempotent.
_repair_advertise_address() {
  local api_ip
  if ! api_ip=$(_resolve_api_address); then
    fail "could not resolve any IPv4 (Tailscale or default-gateway) — repair aborted"
    return 1
  fi
  note "repairing advertise-address: 1.1.1.1 -> $api_ip"

  if [ ! -f /etc/k0s/k0s.yaml ]; then
    mkdir -p /etc/k0s
    cat >/etc/k0s/k0s.yaml <<EOF
# Managed by scripts/bootstrap-robot.sh phase cluster (self-heal path).
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    address: $api_ip
EOF
    info "wrote /etc/k0s/k0s.yaml"
  else
    info "/etc/k0s/k0s.yaml already present — leaving as-is"
  fi

  # Make the systemd unit reference the config file.
  local dropin=/etc/systemd/system/k0scontroller.service.d/use-config.conf
  mkdir -p "$(dirname "$dropin")"
  cat >"$dropin" <<EOF
# Managed by scripts/bootstrap-robot.sh phase cluster (self-heal path).
[Service]
ExecStart=
ExecStart=/usr/local/bin/k0s controller --enable-worker=true --single=true -c /etc/k0s/k0s.yaml
EOF
  systemctl daemon-reload

  if ! systemctl restart k0scontroller; then
    fail "systemctl restart k0scontroller failed"
    return 1
  fi

  # Wait up to 60s for the API to come back.
  local i
  for i in $(seq 1 30); do
    if k0s kubectl get nodes >/dev/null 2>&1; then
      pass "k0scontroller restarted; API reachable (api.address=$api_ip)"
      return 0
    fi
    sleep 2
  done
  fail "k0scontroller restarted but API didn't come back within 60s"
  return 1
}

# Detect a hostname change after k0s install: the kubelet client cert
# is signed with CN=system:node:<old-hostname> but `hostname` now
# returns something different. Symptom in journalctl is endless
# "nodes \"<new>\" not found" + "leases ... cannot get resource"
# because kubelet identifies as the old name and can't claim the new
# node's lease. Cluster never goes Ready -> phase 12's `kubectl wait`
# times out -> bootstrap halts with a misleading dma-ethercat banner.
#
# Returns 0 if a mismatch is detected, 1 otherwise (cert missing,
# unreadable, or matches). Quiet on success/no-cert; the caller
# decides whether to surface and what to do.
KUBELET_CLIENT_CERT="${KUBELET_CLIENT_CERT:-/var/lib/k0s/kubelet/pki/kubelet-client-current.pem}"
_kubelet_cert_hostname_mismatch() {
  [ -r "$KUBELET_CLIENT_CERT" ] || return 1
  local cert_cn current_host
  cert_cn=$(openssl x509 -in "$KUBELET_CLIENT_CERT" -noout -subject 2>/dev/null \
    | sed -nE 's|.*CN[[:space:]]*=[[:space:]]*system:node:([^,/[:space:]]+).*|\1|p')
  [ -n "$cert_cn" ] || return 1
  current_host=$(hostname)
  [ -n "$current_host" ] || return 1
  [ "$cert_cn" != "$current_host" ]
}

# Heal a cluster whose kubelet identity no longer matches the host's
# hostname. The only reliable fix is `k0s reset` + reinstall: certs,
# kine DB, and registered node identity are all baked in at install
# time. Image bundles under /var/lib/k0s/images/ are preserved across
# the reset (k0s reset wipes the whole data dir, but our
# phantomos-k0s-images .deb owns those files — we stash and restore
# them so the operator doesn't have to reinstall the .deb).
#
# After this returns 0, the caller falls through to the normal install
# path (which will see /etc/k0s/k0s.yaml gone and re-run `k0s install`).
_reset_for_hostname_change() {
  local cert_cn current_host
  cert_cn=$(openssl x509 -in "$KUBELET_CLIENT_CERT" -noout -subject 2>/dev/null \
    | sed -nE 's|.*CN[[:space:]]*=[[:space:]]*system:node:([^,/[:space:]]+).*|\1|p')
  current_host=$(hostname)
  note "hostname change detected: kubelet cert CN=$cert_cn, hostname=$current_host"
  note "k0s identity is baked in at install time; running 'k0s reset' to rebuild"

  # Stash image bundles before reset wipes /var/lib/k0s. Restored after
  # so phase 3's import check doesn't come up empty.
  local img_save=""
  if [ -d /var/lib/k0s/images ] \
     && find /var/lib/k0s/images -maxdepth 1 -name '*.tar' -type f 2>/dev/null \
        | grep -q .; then
    img_save=$(mktemp -d -t k0s-images-save-XXXXXX)
    if mv /var/lib/k0s/images/*.tar "$img_save/" 2>/dev/null; then
      info "stashed image bundles under $img_save"
    else
      img_save=""
      info "could not stash image bundles; reset will wipe them — reinstall phantomos-k0s-images afterward"
    fi
  fi

  systemctl stop k0scontroller k0sworker 2>/dev/null || true
  if ! k0s reset 2>&1 | sed 's/^/    /' ; then
    fail "k0s reset failed"
    [ -n "$img_save" ] && rm -rf "$img_save"
    return 1
  fi
  pass "k0s reset (data dir wiped, systemd unit removed)"

  # Drop our generated config so the install path runs fresh and writes
  # a new one against the current hostname / API IP. Operator-edited
  # k0s.yaml would also be replaced — the prior file is unrecoverable
  # at this point anyway since kine is gone.
  rm -f /etc/k0s/k0s.yaml

  # Restore image bundles into the (recreated) data dir.
  if [ -n "$img_save" ]; then
    mkdir -p /var/lib/k0s/images
    if mv "$img_save"/*.tar /var/lib/k0s/images/ 2>/dev/null; then
      pass "restored $(find /var/lib/k0s/images -maxdepth 1 -name '*.tar' -type f | wc -l) image bundle(s)"
    else
      info "could not restore image bundles from $img_save (left in place for manual recovery)"
    fi
    rmdir "$img_save" 2>/dev/null || true
  fi

  return 0
}

# Reconcile foundation.bot/* labels on $1 (node name) against the
# desired set: foundation.bot/robot=true plus host-config.yaml's
# nodeLabels:. Adds/updates desired labels; removes any
# foundation.bot/* label currently on the node that's no longer in
# the desired set. Labels outside the foundation.bot/ prefix are
# left untouched.
_reconcile_node_labels() {
  local node="$1"
  local hc_path="/etc/phantomos/host-config.yaml"
  [ -f "$hc_path" ] || hc_path="$REPO_ROOT/host-config.yaml"

  # Desired = nodeLabels: from host-config + registry defaults +
  # the unconditional foundation.bot/robot=true.
  local desired_json='{}'
  if [ -f "$hc_path" ]; then
    if ! desired_json=$(python3 "$HOST_CONFIG_HELPER" "$hc_path" \
           get-node-labels-json 2>/dev/null); then
      desired_json='{}'
    fi
  fi
  # Bootstrap-managed labels:
  #   foundation.bot/robot: always 'true' — overrides anything in host-config.
  #   foundation.bot/has-*:  every entry in host-config.py's NODE_LABEL_REGISTRY
  #     is filled in to its default value when not explicitly set in
  #     host-config.yaml's nodeLabels:. Operator-set values win.
  #     Validator enforces mutual exclusion of has-positronic/has-locomotion.
  local defaults_tsv
  defaults_tsv=$(python3 "$HOST_CONFIG_HELPER" /dev/null \
                  get-node-label-defaults 2>/dev/null || true)
  while IFS=$'\t' read -r key default _desc; do
    [ -n "$key" ] || continue
    desired_json=$(printf '%s' "$desired_json" \
      | jq --arg k "$key" --arg v "$default" \
          'if has($k) then . else . + {($k): $v} end')
  done <<< "$defaults_tsv"
  desired_json=$(printf '%s' "$desired_json" \
    | jq '. + {"foundation.bot/robot": "true"}')

  # Apply each desired label.
  local key value
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    if "${KUBECTL[@]}" label node "$node" \
         "$key=$value" --overwrite >/dev/null 2>&1; then
      info "labeled $key=$value"
    else
      fail "could not label $key=$value"
      return 1
    fi
  done < <(printf '%s' "$desired_json" \
            | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  # Remove foundation.bot/* labels that aren't desired anymore.
  local current
  current=$("${KUBECTL[@]}" get node "$node" -o json 2>/dev/null \
    | jq -r '(.metadata.labels // {}) | keys[] | select(startswith("foundation.bot/"))')
  local stale_key
  while IFS= read -r stale_key; do
    [ -n "$stale_key" ] || continue
    if printf '%s' "$desired_json" | jq -e --arg k "$stale_key" 'has($k)' \
         >/dev/null; then
      continue   # still in desired set
    fi
    if "${KUBECTL[@]}" label node "$node" "${stale_key}-" >/dev/null 2>&1; then
      info "removed stale label $stale_key"
    else
      info "could not remove stale label $stale_key (continuing)"
    fi
  done <<<"$current"

  return 0
}

cluster() {
  if [ "$SKIP_CLUSTER" = 1 ]; then phase "phase 3: cluster  (skipped)"; return; fi
  phase "phase 3: cluster"

  # Image-source visibility: k0s imports anything in <data-dir>/images/
  # into containerd at worker startup, before kubelet runs. List what's
  # staged so the operator can confirm the phantomos-k0s-images .deb
  # actually delivered files (and that pulls won't quietly fall through
  # to DockerHub for refs we expected to be local).
  local _img_dir=/var/lib/k0s/images
  if [ -d "$_img_dir" ]; then
    local _bundle_count _bundle_total _tar
    _bundle_count=$(find "$_img_dir" -maxdepth 1 -name '*.tar' -type f 2>/dev/null | wc -l)
    if [ "$_bundle_count" -gt 0 ]; then
      _bundle_total=$(du -ch "$_img_dir"/*.tar 2>/dev/null | tail -1 | awk '{print $1}')
      info "image bundles in $_img_dir/ (${_bundle_count} files, ${_bundle_total} total):"
      for _tar in "$_img_dir"/*.tar; do
        info "  $(basename "$_tar") ($(du -h "$_tar" | awk '{print $1}'))"
      done
      info "k0s will import these into containerd at worker startup; matching image: refs will be satisfied locally (no DockerHub pull)"
    else
      info "image bundles in $_img_dir/: none — pulls will go to upstream registries"
      info "  install dist/phantomos-k0s-images-*.deb to pre-stage images"
    fi
  else
    info "image bundles dir $_img_dir/ does not exist yet (k0s will create it)"
  fi

  # Tailscale is preferred (spec.api.address pins to its mesh IP when
  # available) but not required: _resolve_api_address falls back to the
  # default-gateway IP, and --no-tailscale skips it entirely. This call
  # only surfaces the tailscale state as a diagnostic; it always succeeds.
  if [ "$DRY_RUN" = 0 ]; then
    _require_tailscale || return
  fi

  # Hostname-change self-heal: must happen BEFORE the already_running
  # check, because a hostname-mismatch cluster IS technically "running"
  # — k0scontroller is up, but kubelet can't register the renamed node.
  # Reset rebuilds k0s with the current hostname; we then fall through
  # into the normal install path.
  if [ "$DRY_RUN" = 0 ] && _kubelet_cert_hostname_mismatch; then
    _reset_for_hostname_change || return
  fi

  local already_running=0
  systemctl is-active --quiet k0scontroller && already_running=1
  systemctl is-active --quiet k0sworker     && already_running=1

  if [ "$already_running" = 1 ]; then
    # Self-heal path: detect the install-time race.
    if [ "$DRY_RUN" = 0 ] && _apiserver_advertises_sentinel; then
      _repair_advertise_address || return
    else
      skip "k0s already running ($(systemctl is-active k0scontroller k0sworker 2>/dev/null | tr '\n' ' '))"
    fi
  elif [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  resolve api IP ($([ "$NO_TAILSCALE" = 1 ] && echo "default-gateway; --no-tailscale" || echo "tailscale-first, default-gateway fallback"))"
    info "DRY-RUN  write /etc/k0s/k0s.yaml with spec.api.address=<resolved_ip>"
    info "DRY-RUN  k0s install controller --single --enable-worker -c /etc/k0s/k0s.yaml"
    info "DRY-RUN  systemctl enable --now k0scontroller"
  else
    if [ ! -e /etc/k0s/k0s.yaml ]; then
      local api_ip
      if ! api_ip=$(_resolve_api_address); then
        fail "could not resolve any IPv4 for cluster API. Either bring tailscale up, or ensure the host has a default IPv4 route (e.g. 'ip route show default')."
        return
      fi
      info "cluster API server will bind to: $api_ip"
      mkdir -p /etc/k0s
      cat >/etc/k0s/k0s.yaml <<EOF
# Managed by scripts/bootstrap-robot.sh phase cluster.
# Pinning spec.api.address prevents k0s from baking '1.1.1.1' (its
# 'no default route' sentinel) into kine when the network isn't fully
# up at install time. Edit at your own risk; bootstrap respects an
# operator-modified file (re-runs skip the install path entirely when
# this file is present).
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    address: $api_ip
EOF
      if k0s install controller --single --enable-worker -c /etc/k0s/k0s.yaml; then
        pass "k0s installed (api.address=$api_ip)"
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

  # Verify the bundles we listed above actually got imported into k0s's
  # containerd. Worker startup imports happen before kubelet, so by the
  # time the node is Ready the import is either done or failed silently.
  # Surfacing this prevents the failure mode where pods quietly pull
  # from DockerHub even though we shipped a local image bundle.
  if [ "$DRY_RUN" = 0 ] && [ -d "$_img_dir" ] \
     && find "$_img_dir" -maxdepth 1 -name '*.tar' -type f 2>/dev/null | grep -q .; then
    local _ctr_count
    _ctr_count=$(k0s ctr -n k8s.io images list -q 2>/dev/null | wc -l)
    if [ "$_ctr_count" -gt 0 ]; then
      pass "containerd has $_ctr_count image(s) loaded from $_img_dir/ bundles"
    else
      info "containerd image namespace is empty — bundles may have failed to import"
      info "  diagnose: journalctl -u k0scontroller | grep -iE 'image|bundle|import'"
    fi
  fi

  # Reconcile the foundation.bot/* node-label namespace from
  # host-config.yaml. Bootstrap manages this prefix as a closed set:
  # foundation.bot/robot=true is unconditional; everything else comes
  # from nodeLabels:. Labels under the prefix that are no longer in
  # host-config get removed. Labels OUTSIDE the prefix are not touched.
  # Robot-specific DaemonSets (yovariable-server, cpp-state-estimator,
  # dma-recorder, future has-imu workloads, ...) gate on these labels
  # via nodeSelector.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  reconcile foundation.bot/* node labels from host-config"
  else
    local node_name
    node_name=$("${KUBECTL[@]}" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$node_name" ]; then
      fail "could not resolve node name for label reconciliation"
    elif _reconcile_node_labels "$node_name"; then
      pass "node labels reconciled on $node_name"
    else
      fail "node label reconciliation failed"
    fi
  fi

  # Write a kubeconfig for root so kubectl + terraform have one to read.
  # `k0s kubeconfig admin` regenerates from the cluster CA every time —
  # safe to run repeatedly. We pin the server URL to 127.0.0.1: the only
  # consumers are local (kubectl, terraform, both run on this host),
  # the cert SANs include 127.0.0.1, and loopback is immune to wifi
  # DHCP changes / network moves that would otherwise stale the file.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  k0s kubeconfig admin > /root/.kube/config (server=127.0.0.1, chmod 600)"
  else
    mkdir -p /root/.kube
    local kc_tmp
    kc_tmp=$(mktemp)
    if k0s kubeconfig admin 2>/dev/null \
         | sed 's|server: https://[^:]*:6443|server: https://127.0.0.1:6443|' \
         > "$kc_tmp" && [ -s "$kc_tmp" ]; then
      install -m 0600 "$kc_tmp" /root/.kube/config
      rm -f "$kc_tmp"
      pass "/root/.kube/config written (server=127.0.0.1, $(wc -c </root/.kube/config) bytes)"
    else
      rm -f "$kc_tmp"
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
    # Soft-skip rather than hard-fail: a robot whose images are fully
    # pre-staged via the phantomos-k0s-images .deb doesn't need
    # DockerHub credentials at all (pods with imagePullPolicy:
    # IfNotPresent reuse what k0s imported into containerd at worker
    # startup). Halting bootstrap here would also halt phase 13 (gitops)
    # and leave the cluster with no Applications. If any pod actually
    # needs a DockerHub pull, it'll surface as ImagePullBackOff later —
    # the right place for that signal, not the bootstrap.
    skip "$PULL_SECRET_NAME unavailable in: ${missing[*]}"
    info "  pods needing DockerHub pulls will ImagePullBackOff. OK if all"
    info "  images are pre-staged via phantomos-k0s-images-*.deb."
    info "  Otherwise re-run with --dockerhub-secret-file <path> or"
    info "  'sudo docker login' to populate /root/.docker/config.json."
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

# Extract the host portion from "http(s)://host(:port)(/path)". Emits
# the bare host; returns 1 if the input has no scheme or empty host.
_url_to_host() {
  local url="${1:?_url_to_host: url required}"
  local rest="${url#*://}"
  local host="${rest%%[:/]*}"
  [ -n "$host" ] || return 1
  printf '%s\n' "$host"
}

# Render the ConfigMap manifest into PAIRING_FILE. Caller is
# responsible for being root.
#
# Three keys land in the CM:
#   AI_PC_HOST       — the AI PC's per-host Tailscale IP / FQDN
#                      (operator-ui composes AI_PC_URL=http://$(AI_PC_HOST):5000;
#                      vr-web composes CAMERA_SERVER_URL=http://$(AI_PC_HOST):8889).
#                      vr-web's ROSBRIDGE_URL is no longer AI-PC-derived —
#                      it targets the on-robot dma-bridge at
#                      ws://$(NODE_IP):9098 (downward-API node IP).
#   CONTROL_PC_HOST  — the robot's own externally-reachable address
#                      (operator-ui composes CONTROL_PC_URL=http://$(CONTROL_PC_HOST):5000;
#                      phantomos-api-server runs hostNetwork in the
#                      phantom ns with hostPort 5000, so the operator's
#                      browser hits the robot directly there).
#   ROBOT            — the robot identifier (e.g. "mk11000009").
#                      operator-ui's robotConfig.ts looks this up to
#                      derive the camera server URL; without it the
#                      Camera Hub falls back to localhost:8889 and
#                      shows every camera offline. Defaults to
#                      $(hostname); override with ROBOT_ID_OVERRIDE.
_write_pairing_file() {
  local ai_pc_host="${1:?_write_pairing_file: ai_pc_host required}"
  local control_pc_host="${2:?_write_pairing_file: control_pc_host required}"
  local robot_id="${3:?_write_pairing_file: robot_id required}"
  mkdir -p "$(dirname "$PAIRING_FILE")"
  cat > "$PAIRING_FILE" <<EOF
# Generated by scripts/bootstrap-robot.sh — do not hand-edit.
# Re-run bootstrap with --ai-pc-url (and/or --control-pc-host) to change.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $PAIRING_CM_NAME
  namespace: $PAIRING_NS
data:
  AI_PC_HOST: $ai_pc_host
  CONTROL_PC_HOST: $control_pc_host
  ROBOT: $robot_id
EOF
  chmod 0644 "$PAIRING_FILE"
}

# Resolve the ROBOT identifier the operator-ui pod will see. Defaults
# to $(hostname) (e.g. "mk11000009"), which is the key
# argus.operator-ui's robotConfig.ts registry uses. Override with
# ROBOT_ID_OVERRIDE for hosts whose hostname doesn't match the
# registry (rare; CI fixtures, dev rigs).
_resolve_robot_id() {
  if [ -n "${ROBOT_ID_OVERRIDE:-}" ]; then
    printf '%s\n' "$ROBOT_ID_OVERRIDE"
    return 0
  fi
  hostname
}

# Resolve CONTROL_PC_HOST. Same address k0s binds spec.api.address to —
# Tailscale IP first (so the operator's tablet uses the same mesh
# address it already uses for the cluster API), default-gateway IPv4
# fallback. Override with CONTROL_PC_HOST_OVERRIDE for hosts where
# auto-resolution picks the wrong NIC (e.g. dual-homed dev rigs).
_resolve_control_pc_host() {
  if [ -n "${CONTROL_PC_HOST_OVERRIDE:-}" ]; then
    printf '%s\n' "$CONTROL_PC_HOST_OVERRIDE"
    return 0
  fi
  _resolve_api_address
}

# Read AI_PC_HOST out of an existing PAIRING_FILE. Falls back to
# extracting from a legacy AI_PC_URL key (pre-FIR-330 files). Echoes
# the host; returns 1 if neither key is present / parseable.
_read_ai_pc_host_from_file() {
  [ -r "$PAIRING_FILE" ] || return 1
  local h
  h=$(awk '
    /^[[:space:]]*AI_PC_HOST:[[:space:]]*/ {
      sub(/^[[:space:]]*AI_PC_HOST:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }' "$PAIRING_FILE")
  if [ -n "$h" ]; then
    printf '%s\n' "$h"
    return 0
  fi
  # Legacy AI_PC_URL fallback.
  local legacy
  legacy=$(awk '
    /^[[:space:]]*AI_PC_URL:[[:space:]]*/ {
      sub(/^[[:space:]]*AI_PC_URL:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }' "$PAIRING_FILE")
  [ -n "$legacy" ] || return 1
  _url_to_host "$legacy"
}

operator_ui_config() {
  if [ "$SKIP_OPERATOR_UI_CONFIG" = 1 ]; then phase "phase 6: operator-ui-config  (skipped)"; return; fi
  phase "phase 6: operator-ui-config (AI_PC_HOST ConfigMap + vr-web TLS)"

  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$AI_PC_URL" ]; then
      info "DRY-RUN  write $PAIRING_FILE  AI_PC_HOST=<from $AI_PC_URL>  CONTROL_PC_HOST=<_resolve_api_address>  ROBOT=<hostname>"
      info "DRY-RUN  kubectl apply -f $PAIRING_FILE"
    elif [ -r "$PAIRING_FILE" ]; then
      info "DRY-RUN  rewrite $PAIRING_FILE preserving AI_PC_HOST, refreshing CONTROL_PC_HOST + ROBOT"
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

  # Determine AI_PC_HOST: --ai-pc-url overrides; otherwise read the
  # existing PAIRING_FILE (which auto-migrates pre-FIR-330 files that
  # still hold AI_PC_URL).
  local ai_pc_host=""
  if [ -n "$AI_PC_URL" ]; then
    case "$AI_PC_URL" in
      http://*|https://*) ;;
      *) fail "--ai-pc-url must start with http:// or https:// (got: $AI_PC_URL)"; return ;;
    esac
    ai_pc_host=$(_url_to_host "$AI_PC_URL") || {
      fail "could not extract host from --ai-pc-url '$AI_PC_URL'"
      return
    }
  elif [ -r "$PAIRING_FILE" ]; then
    ai_pc_host=$(_read_ai_pc_host_from_file) || {
      fail "cannot derive AI_PC_HOST from $PAIRING_FILE — re-run with --ai-pc-url"
      return
    }
  else
    fail "$PAIRING_FILE missing — first bringup needs --ai-pc-url <url>"
    return
  fi

  # CONTROL_PC_HOST is always resolved fresh — the robot's reachable
  # address can shift (Tailscale rejoin, NIC change), and there's no
  # cost to rewriting since we rollout-restart operator-ui below.
  local control_pc_host
  control_pc_host=$(_resolve_control_pc_host) || {
    fail "could not resolve CONTROL_PC_HOST (no tailscale IP, no default IPv4 route)"
    info "  set CONTROL_PC_HOST_OVERRIDE=<ip-or-fqdn> and re-run"
    return
  }

  # ROBOT identifier for operator-ui's robotConfig.ts lookup
  # (drives camera server URL resolution). Defaults to $(hostname).
  local robot_id
  robot_id=$(_resolve_robot_id) || {
    fail "could not resolve ROBOT id (hostname failed?)"
    return
  }

  _write_pairing_file "$ai_pc_host" "$control_pc_host" "$robot_id" || return
  pass "wrote $PAIRING_FILE  AI_PC_HOST=$ai_pc_host  CONTROL_PC_HOST=$control_pc_host  ROBOT=$robot_id"

  if ! "${KUBECTL[@]}" apply -f "$PAIRING_FILE" >/dev/null; then
    fail "kubectl apply -f $PAIRING_FILE"
    return
  fi
  pass "$PAIRING_CM_NAME applied to $PAIRING_NS"

  # CM changes don't auto-propagate — Kubernetes resolves
  # configMapKeyRef / envFrom only at pod start. Roll the consumers:
  #   - operator-ui: uses ENV/GATEWAY_URL only now, but historically
  #     consumed AI_PC_HOST; restart for safety on migrations.
  #   - nginx: its init container envFrom's the CM to render upstreams
  #     for /api/ai/ and /api/control/. Must re-run on any CM change.
  #   - vr-web: deferred to the TLS sub-phase below so the restart
  #     happens after /opt/certs is populated (otherwise the
  #     discover-tls init container would CrashLoopBackOff).
  for dep in operator-ui nginx; do
    if "${KUBECTL[@]}" -n "$PAIRING_NS" get deploy "$dep" >/dev/null 2>&1; then
      if "${KUBECTL[@]}" -n "$PAIRING_NS" rollout restart deploy/"$dep" >/dev/null; then
        pass "rolled out $dep to pick up new pairing values"
      else
        fail "rollout restart deploy/$dep"
      fi
    else
      info "deploy/$dep not present yet — gitops phase will create it with the new CM in scope"
    fi
  done

  # ---- sub-phase: vr-web TLS cert (Tailscale-issued, /opt/certs/) -----
  #
  # WebXR (Quest 3) requires HTTPS. The vr-web Pod's discover-tls init
  # container reads /opt/certs/*.{crt,key} on the host via hostPath, so
  # the cert pair must exist on disk before vr-web rolls out. We issue
  # (or re-issue) a per-host Tailscale cert here so the operator
  # doesn't have to remember the `tailscale cert` invocation.
  #
  #   1. If /opt/certs already has a *.crt + *.key pair, prompts the
  #      operator (interactive only) to wipe and re-issue. Default
  #      answer is N (preserve) — `tailscale cert` is rate-limited
  #      against Let's Encrypt and a working cert needs no churn.
  #      In non-interactive runs (-y or no TTY) the pair is
  #      preserved; set VR_WEB_TLS_RENEW=1 to force re-issue.
  #   2. If /opt/certs is empty (or operator chose to wipe), runs
  #      `tailscale cert <FQDN>` inside /opt/certs/ so <FQDN>.crt
  #      and <FQDN>.key land directly under the hostPath. FQDN is
  #      derived from `tailscale status --json` (Self.DNSName) so we
  #      don't hard-code the tailnet suffix; override with
  #      VR_WEB_TLS_FQDN=<fqdn>.
  #   3. chowns the resulting pair to $SUDO_USER (matches the
  #      operator's manual workflow), then rolls vr-web so the
  #      Pod's discover-tls init container picks up the new pair.
  #
  # Soft-fails if the host has no `tailscale` CLI / not Running; the
  # vr-web Pod will stay in init CrashLoopBackOff with a "no cert/key
  # in /opt/certs" message until the operator drops a pair in by hand.
  VR_WEB_TLS_DIR="${VR_WEB_TLS_DIR:-/opt/certs}"

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  ensure $VR_WEB_TLS_DIR has a Tailscale-issued cert pair"
    info "DRY-RUN  (prompt to wipe + re-issue if present; issue from tailscale if absent)"
    info "DRY-RUN  rollout restart deploy/vr-web in $PAIRING_NS"
    return
  fi

  local fqdn issued=0 reply existing
  fqdn=$(_vr_web_tls_resolve_fqdn)
  info "vr-web TLS FQDN: $fqdn  (override via VR_WEB_TLS_FQDN)"

  if _vr_web_tls_pair_present "$VR_WEB_TLS_DIR"; then
    existing=$(ls "$VR_WEB_TLS_DIR"/*.crt 2>/dev/null | head -1)
    if [ "$YES" = 1 ] || [ ! -t 0 ]; then
      if [ "${VR_WEB_TLS_RENEW:-0}" = 1 ]; then
        info "VR_WEB_TLS_RENEW=1; wiping $VR_WEB_TLS_DIR and re-issuing"
        rm -f "$VR_WEB_TLS_DIR"/*.crt "$VR_WEB_TLS_DIR"/*.key
        _vr_web_tls_issue "$fqdn" "$VR_WEB_TLS_DIR" && issued=1
      else
        skip "cert pair present in $VR_WEB_TLS_DIR ($(basename "$existing")); preserving (VR_WEB_TLS_RENEW=1 to force)"
      fi
    else
      printf 'cert pair already present in %s (%s).\nWipe and re-issue from tailscale? [y/N] ' \
        "$VR_WEB_TLS_DIR" "$(basename "$existing")"
      read -r reply || true
      if [[ "$reply" =~ ^[Yy] ]]; then
        rm -f "$VR_WEB_TLS_DIR"/*.crt "$VR_WEB_TLS_DIR"/*.key
        _vr_web_tls_issue "$fqdn" "$VR_WEB_TLS_DIR" && issued=1
      else
        skip "preserving existing $VR_WEB_TLS_DIR cert pair"
      fi
    fi
  else
    info "no cert pair in $VR_WEB_TLS_DIR; issuing from tailscale"
    _vr_web_tls_issue "$fqdn" "$VR_WEB_TLS_DIR" && issued=1
  fi

  if [ "$issued" = 1 ]; then
    pass "issued $fqdn.crt + $fqdn.key in $VR_WEB_TLS_DIR"
  fi

  # Always rollout-restart vr-web so it picks up either the new
  # pairing CM, the new cert pair, or both. No-op if vr-web hasn't
  # been created yet by the gitops phase.
  if "${KUBECTL[@]}" -n "$PAIRING_NS" get deploy vr-web >/dev/null 2>&1; then
    if "${KUBECTL[@]}" -n "$PAIRING_NS" rollout restart deploy/vr-web >/dev/null; then
      pass "rolled out vr-web (pairing CM + /opt/certs)"
    else
      fail "rollout restart deploy/vr-web"
    fi
  else
    info "deploy/vr-web not present yet — gitops phase will create it with cert + CM in scope"
  fi
}

# Resolve the FQDN to request a Tailscale cert for. Preference:
#   1. VR_WEB_TLS_FQDN env override (e.g. set by a CI harness).
#   2. `tailscale status --json` Self.DNSName — this is the canonical
#      name the admin console signs certs for, so it can't drift from
#      the tailnet suffix configured upstream.
#   3. Hardcoded foundation-bot.ts.net fallback for hosts where
#      tailscaled isn't reachable but the operator still wants to
#      kick the cert flow (rare; the issue step will fail loudly).
_vr_web_tls_resolve_fqdn() {
  if [ -n "${VR_WEB_TLS_FQDN:-}" ]; then
    printf '%s\n' "$VR_WEB_TLS_FQDN"
    return 0
  fi
  if command -v tailscale >/dev/null 2>&1; then
    local dns
    dns=$(tailscale status --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName",""))' 2>/dev/null \
      | sed 's/\.$//')
    if [ -n "$dns" ]; then
      printf '%s\n' "$dns"
      return 0
    fi
  fi
  printf '%s.foundation-bot.ts.net\n' "$(hostname)"
}

# Returns 0 if $1/{*.crt,*.key} both have at least one matching file.
# Uses nullglob so empty directories don't return the literal "*.crt"
# pattern as a false positive.
_vr_web_tls_pair_present() {
  local dir="${1:?_vr_web_tls_pair_present: dir required}"
  [ -d "$dir" ] || return 1
  local crt key
  shopt -s nullglob
  crt=( "$dir"/*.crt )
  key=( "$dir"/*.key )
  shopt -u nullglob
  [ "${#crt[@]}" -gt 0 ] && [ "${#key[@]}" -gt 0 ]
}

# Issue a Tailscale cert for $fqdn into $dir. `tailscale cert` writes
# <fqdn>.crt + <fqdn>.key to cwd, so we run it in a subshell with cwd
# pinned to $dir; the script's own cwd is unaffected. chowns the pair
# to $SUDO_USER so the operator can inspect/copy without sudo.
_vr_web_tls_issue() {
  local fqdn="${1:?_vr_web_tls_issue: fqdn required}"
  local dir="${2:?_vr_web_tls_issue: dir required}"
  if ! command -v tailscale >/dev/null 2>&1; then
    fail "tailscale CLI not installed; cannot issue $dir cert"
    info "  install tailscale, sign in, then re-run: sudo bash $0 --operator-ui-config"
    return 1
  fi
  mkdir -p "$dir"
  if ! ( cd "$dir" && tailscale cert "$fqdn" ); then
    fail "tailscale cert $fqdn"
    info "  ensure the machine is signed in (\`tailscale status\`) and HTTPS"
    info "  is enabled for this tailnet in the admin console."
    return 1
  fi
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    local grp
    grp=$(id -gn "$SUDO_USER")
    chown "$SUDO_USER:$grp" "$dir"/*.crt "$dir"/*.key 2>/dev/null || true
  fi
  return 0
}

# ---- phase 7: locomotion-config (LOCOMOTION_POLICY ConfigMap) -----

# Per-host locomotion policy file. Holds a ConfigMap manifest the
# phantom-locomotion DaemonSet's main container reads via envFrom.
# Same pattern as operator-ui-pairing: lives on the host (not in
# git), --reset preserves it, ArgoCD doesn't reconcile it.
LOCOMOTION_FILE="${LOCOMOTION_FILE:-/etc/phantomos/phantom-locomotion-config.yaml}"
LOCOMOTION_NS="positronic"
LOCOMOTION_CM_NAME="phantom-locomotion-config"

_write_locomotion_file() {
  # Takes a single multi-line KEY=VALUE blob (as produced by the
  # host-config helper's `get-phantom-locomotion-config-kv` subcommand)
  # and renders one YAML-quoted `KEY: "VALUE"` entry per non-empty line
  # under the ConfigMap's data: section. Quoting keeps characters like
  # '/', '=', '.' safe regardless of the value's shape.
  local kv_text="${1?_write_locomotion_file: kv_text required}"
  mkdir -p "$(dirname "$LOCOMOTION_FILE")"
  {
    cat <<EOF
# Generated by scripts/bootstrap-robot.sh — do not hand-edit.
# Re-run bootstrap with --locomotion-config to change the value.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $LOCOMOTION_CM_NAME
  namespace: $LOCOMOTION_NS
data:
EOF
    local line key value
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key="${line%%=*}"
      value="${line#*=}"
      printf '  %s: "%s"\n' "$key" "$value"
    done <<<"$kv_text"
  } > "$LOCOMOTION_FILE"
  chmod 0644 "$LOCOMOTION_FILE"
}

locomotion_config() {
  if [ "${SKIP_LOCOMOTION_CONFIG:-0}" = 1 ]; then
    phase "phase 7: locomotion-config  (skipped)"
    return
  fi
  phase "phase 7: locomotion-config (LOCOMOTION_POLICY ConfigMap)"

  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi

  local kv_text=""
  if [ -r "$hc" ]; then
    kv_text=$(python3 "$HOST_CONFIG_HELPER" "$hc" get-phantom-locomotion-config-kv 2>/dev/null || true)
  fi
  if [ -z "$kv_text" ]; then
    # Helper failed (no host-config, validation error, etc.) — fall back
    # to the documented default so the pod still starts.
    kv_text="LOCOMOTION_MODE=policy
LOCOMOTION_POLICY=mk2-walking-lower-body-1imu"
  fi

  # Extract a short summary for the log lines. `grep -m1` keeps this
  # robust against extra keys appearing further down the blob (diagnostic
  # mode adds several LOCOMOTION_DIAGNOSTIC_* lines).
  local mode_line policy_line mode policy
  mode_line=$(printf '%s\n' "$kv_text" | grep -m1 '^LOCOMOTION_MODE=' || true)
  policy_line=$(printf '%s\n' "$kv_text" | grep -m1 '^LOCOMOTION_POLICY=' || true)
  mode="${mode_line#LOCOMOTION_MODE=}"
  policy="${policy_line#LOCOMOTION_POLICY=}"

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  write $LOCOMOTION_FILE  LOCOMOTION_MODE=$mode LOCOMOTION_POLICY=$policy"
    info "DRY-RUN  kubectl apply -f $LOCOMOTION_FILE"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot apply locomotion ConfigMap"
    return
  fi

  if ! "${KUBECTL[@]}" get ns "$LOCOMOTION_NS" >/dev/null 2>&1; then
    if ! "${KUBECTL[@]}" create ns "$LOCOMOTION_NS" >/dev/null; then
      fail "could not create ns/$LOCOMOTION_NS"
      return
    fi
    info "created ns/$LOCOMOTION_NS"
  fi

  _write_locomotion_file "$kv_text"
  pass "wrote $LOCOMOTION_FILE  LOCOMOTION_POLICY=$policy"
  pass "phantom-locomotion-config: LOCOMOTION_MODE=$mode LOCOMOTION_POLICY=$policy"

  if ! "${KUBECTL[@]}" apply -f "$LOCOMOTION_FILE" >/dev/null; then
    fail "kubectl apply -f $LOCOMOTION_FILE"
    return
  fi
  pass "$LOCOMOTION_CM_NAME applied to $LOCOMOTION_NS"

  # If the DaemonSet is already running, restart it so the new policy
  # takes effect. envFrom does NOT auto-roll on CM updates.
  if "${KUBECTL[@]}" -n "$LOCOMOTION_NS" get ds phantom-locomotion >/dev/null 2>&1; then
    if "${KUBECTL[@]}" -n "$LOCOMOTION_NS" rollout restart ds/phantom-locomotion >/dev/null; then
      pass "rolled out phantom-locomotion DaemonSet to pick up new policy"
    else
      fail "rollout restart ds/phantom-locomotion"
    fi
  else
    info "ds/phantom-locomotion not present yet — gitops phase will create it with the new CM in scope"
  fi
}

# ---- phase 8: sonic-config (phantom-sonic-config ConfigMap) -------

# Per-host phantom-sonic options file. Holds a ConfigMap manifest the
# four phantom-sonic containers read via envFrom. Same host-resident,
# ArgoCD-unmanaged, --reset-preserved lifecycle as the locomotion CM.
SONIC_FILE="${SONIC_FILE:-/etc/phantomos/phantom-sonic-config.yaml}"
SONIC_NS="positronic"
SONIC_CM_NAME="phantom-sonic-config"

_write_sonic_file() {
  # Render a single multi-line KEY=VALUE blob (as produced by the
  # host-config helper's `get-phantom-sonic-config-kv` subcommand) into
  # one YAML-quoted `KEY: "VALUE"` entry per non-empty line under the
  # ConfigMap's data: section.
  local kv_text="${1?_write_sonic_file: kv_text required}"
  mkdir -p "$(dirname "$SONIC_FILE")"
  {
    cat <<EOF
# Generated by scripts/bootstrap-robot.sh — do not hand-edit.
# Re-run bootstrap with --sonic-config to change these values.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $SONIC_CM_NAME
  namespace: $SONIC_NS
data:
EOF
    local line key value
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key="${line%%=*}"
      value="${line#*=}"
      printf '  %s: "%s"\n' "$key" "$value"
    done <<<"$kv_text"
  } > "$SONIC_FILE"
  chmod 0644 "$SONIC_FILE"
}

sonic_config() {
  if [ "${SKIP_SONIC_CONFIG:-0}" = 1 ]; then
    phase "phase 8: sonic-config  (skipped)"
    return
  fi
  phase "phase 8: sonic-config (phantom-sonic-config ConfigMap)"

  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi

  local kv_text=""
  if [ -r "$hc" ]; then
    kv_text=$(python3 "$HOST_CONFIG_HELPER" "$hc" get-phantom-sonic-config-kv 2>/dev/null || true)
  fi
  if [ -z "$kv_text" ]; then
    # Helper failed (no host-config, validation error, etc.) — fall back
    # to the documented defaults so the pod still starts. Keep in sync
    # with DEFAULT_SONIC in scripts/lib/host-config.py and the manifest's
    # shell-defaults.
    kv_text="ROS_DOMAIN_ID=43
SONIC_WALKING_POLICY=mk1-walking-1imu-1
SONIC_ENCODER_MODE=0
MOTION_ZMQ_PORT=5557
CONTROL_ZMQ_PORT=5558
WEB_PORT=7865
MOTION_RAMP_SECS=1.0"
  fi

  local policy_line policy
  policy_line=$(printf '%s\n' "$kv_text" | grep -m1 '^SONIC_WALKING_POLICY=' || true)
  policy="${policy_line#SONIC_WALKING_POLICY=}"

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  write $SONIC_FILE  SONIC_WALKING_POLICY=$policy"
    info "DRY-RUN  kubectl apply -f $SONIC_FILE"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot apply sonic ConfigMap"
    return
  fi

  if ! "${KUBECTL[@]}" get ns "$SONIC_NS" >/dev/null 2>&1; then
    if ! "${KUBECTL[@]}" create ns "$SONIC_NS" >/dev/null; then
      fail "could not create ns/$SONIC_NS"
      return
    fi
    info "created ns/$SONIC_NS"
  fi

  _write_sonic_file "$kv_text"
  pass "wrote $SONIC_FILE  SONIC_WALKING_POLICY=$policy"

  if ! "${KUBECTL[@]}" apply -f "$SONIC_FILE" >/dev/null; then
    fail "kubectl apply -f $SONIC_FILE"
    return
  fi
  pass "$SONIC_CM_NAME applied to $SONIC_NS"

  # If the DaemonSet is already running, restart it so the new options
  # take effect. envFrom does NOT auto-roll on CM updates.
  if "${KUBECTL[@]}" -n "$SONIC_NS" get ds phantom-sonic >/dev/null 2>&1; then
    if "${KUBECTL[@]}" -n "$SONIC_NS" rollout restart ds/phantom-sonic >/dev/null; then
      pass "rolled out phantom-sonic DaemonSet to pick up new options"
    else
      fail "rollout restart ds/phantom-sonic"
    fi
  else
    info "ds/phantom-sonic not present yet — gitops phase will create it with the new CM in scope"
  fi
}

# ---- phase 8b: psi-config (phantom-psi-config ConfigMap) ----------

# Per-host phantom-psi options file. Holds a ConfigMap manifest the four
# phantom-psi containers (psi0-vla, bridge, walking, psi0-state) read via envFrom. Same
# host-resident, ArgoCD-unmanaged, --reset-preserved lifecycle as the sonic CM.
PSI_FILE="${PSI_FILE:-/etc/phantomos/phantom-psi-config.yaml}"
PSI_NS="psi"
PSI_CM_NAME="phantom-psi-config"

_write_psi_file() {
  # Render a single multi-line KEY=VALUE blob (as produced by the host-config
  # helper's `get-phantom-psi-config-kv` subcommand) into one YAML-quoted
  # `KEY: "VALUE"` entry per non-empty line under the ConfigMap's data: section.
  local kv_text="${1?_write_psi_file: kv_text required}"
  mkdir -p "$(dirname "$PSI_FILE")"
  {
    cat <<EOF
# Generated by scripts/bootstrap-robot.sh — do not hand-edit.
# Re-run bootstrap with --psi-config to change these values.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $PSI_CM_NAME
  namespace: $PSI_NS
data:
EOF
    local line key value
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key="${line%%=*}"
      value="${line#*=}"
      printf '  %s: "%s"\n' "$key" "$value"
    done <<<"$kv_text"
  } > "$PSI_FILE"
  chmod 0644 "$PSI_FILE"
}

psi_config() {
  if [ "${SKIP_PSI_CONFIG:-0}" = 1 ]; then
    phase "phase 8b: psi-config  (skipped)"
    return
  fi
  phase "phase 8b: psi-config (phantom-psi-config ConfigMap)"

  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi

  local kv_text=""
  if [ -r "$hc" ]; then
    kv_text=$(python3 "$HOST_CONFIG_HELPER" "$hc" get-phantom-psi-config-kv 2>/dev/null || true)
  fi
  if [ -z "$kv_text" ]; then
    # Helper failed (no host-config, validation error, etc.) — fall back to the
    # documented defaults so the pod still starts. Keep in sync with DEFAULT_PSI
    # in scripts/lib/host-config.py and the manifest's shell-defaults.
    kv_text="PSI0_RUN_DIR=/models/full_task.real.flow1000.cosine.lr1.0e-04.b128.gpus1.2606120333
PSI0_CKPT_STEP=120000
PSI0_CAMERA_ID=0
PSI0_STATE_QUEUE=psi0_state_j24
PSI0_ACTION_QUEUE=psi0_actions_j24
PSI0_INSTRUCTION=Grasp and lift part.
ROS_DOMAIN_ID=43
PSI0_BRIDGE_RATE_HZ=50
PSI0_ENABLE_GAIT=0
PSI0_ENABLE_HEIGHT=0
PSI0_ENABLE_YAW=0
POLICY_ONNX_PATH=/models/walking/policy.onnx
PSI0_LOCO_HEALTH_PATH=/dev/shm/psi0_loco.health
PSI0_LOCO_MIRROR_HZ=5"
  fi

  local run_line run_dir
  run_line=$(printf '%s\n' "$kv_text" | grep -m1 '^PSI0_RUN_DIR=' || true)
  run_dir="${run_line#PSI0_RUN_DIR=}"

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  write $PSI_FILE  PSI0_RUN_DIR=$run_dir"
    info "DRY-RUN  kubectl apply -f $PSI_FILE"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot apply psi ConfigMap"
    return
  fi

  if ! "${KUBECTL[@]}" get ns "$PSI_NS" >/dev/null 2>&1; then
    if ! "${KUBECTL[@]}" create ns "$PSI_NS" >/dev/null; then
      fail "could not create ns/$PSI_NS"
      return
    fi
    info "created ns/$PSI_NS"
  fi

  _write_psi_file "$kv_text"
  pass "wrote $PSI_FILE  PSI0_RUN_DIR=$run_dir"

  if ! "${KUBECTL[@]}" apply -f "$PSI_FILE" >/dev/null; then
    fail "kubectl apply -f $PSI_FILE"
    return
  fi
  pass "$PSI_CM_NAME applied to $PSI_NS"

  # If the DaemonSet is already running, restart it so the new options take
  # effect. envFrom does NOT auto-roll on CM updates.
  if "${KUBECTL[@]}" -n "$PSI_NS" get ds phantom-psi >/dev/null 2>&1; then
    if "${KUBECTL[@]}" -n "$PSI_NS" rollout restart ds/phantom-psi >/dev/null; then
      pass "rolled out phantom-psi DaemonSet to pick up new options"
    else
      fail "rollout restart ds/phantom-psi"
    fi
  else
    info "ds/phantom-psi not present yet — gitops phase will create it with the new CM in scope"
  fi
}

# ---- pre-phase: cpu-isolation first-bringup prompt -------------------

# On first bringup the cpuIsolation: block doesn't exist in
# host-config.yaml yet. Phase 7 (below) reads cpuIsolation.nic.iface
# to know what to name the NIC; phase 10 reads partitions/dmaRtCpu/etc.
# Before this hoist, the prompt that populates the block lived inside
# phase 10 — so phase 9 ran first, saw an empty block, skipped, then
# phase 10 prompted, persisted, and immediately tried to pin IRQs on a
# NIC that nothing had named. Operators had to re-run bootstrap to
# unstick the loop.
#
# Run the same _cpu_isolation_prompt up front so both phases see a
# populated block in the same run. Strictly a TTY-only convenience:
# in dry-run, non-interactive shells, or when both downstream phases
# are skipped, this is a no-op and the existing skip-with-actionable-
# message paths in phases 7 and 8 still fire.
ensure_cpu_isolation_block() {
  # Cheap exits first.
  if [ "$DRY_RUN" = 1 ]; then return; fi
  if [ "$SKIP_ECAT_INTERFACE" = 1 ] && [ "$SKIP_CPU_ISOLATION" = 1 ]; then
    return
  fi
  if [ ! -t 0 ] || [ ! -t 2 ]; then return; fi

  local hc="$HOST_CONFIG_FILE"
  if [ ! -r "$hc" ]; then return; fi

  local ci_json
  ci_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"
  if [ "$ci_json" != "{}" ]; then return; fi

  phase "pre-phase: cpu-isolation first-bringup setup"
  if ! _cpu_isolation_prompt "$hc"; then
    info "operator declined; phases 7 and 8 will skip with their normal messages"
  fi
}

# ---- phase 9: ecat-interface (gates phase 10) -------------------------

# Resolve the EtherCAT NIC adapter and rename it to the requested
# kernel iface name (e.g. ecat0 / ecat1) via persistent udev rules.
# Runs BEFORE phase 10's cpu-isolation because phase 10's NIC IRQ pin
# step (`ethercat-rt --nic <iface>`) requires the named iface to
# already exist.
#
# Driven by host-config cpuIsolation.nic.{iface, selector}. Selector
# block must contain exactly one of {mac, pci, {driver,index}};
# validator enforces this. When selector is absent and stdin is a TTY,
# bootstrap drops to nic_resolve_target_mac_interactive (vendored
# library) and persists the chosen MAC back to host-config so re-runs
# are non-interactive.
#
# Workflow (sources scripts/cpusets/lib/nic_setup.sh — no shell-out):
#   1. resolve target MAC: from selector (mac/pci/driver+index) OR
#      interactive picker on TTY
#   2. nic_already_named && nic_udev_rule_present
#      && nic_link_file_present                    -> no-op
#   3. nic_write_udev_rule    (idempotent line-scoped rewrite)
#   4. nic_write_link_file    (systemd .link pins PHY autoneg/100M/full)
#   5. nic_apply_udev         (reload+trigger+wait for iface)
#
# This explicit guard sequence is what fixes the prior bug where the
# entire shell-out re-ran on every bootstrap and re-renamed an already
# correctly-named interface.
ecat_interface() {
  if [ "$SKIP_ECAT_INTERFACE" = 1 ]; then
    phase "phase 9: ecat-interface  (skipped — --skip-ecat-interface)"
    return
  fi

  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi
  if [ ! -r "$hc" ]; then
    phase "phase 9: ecat-interface  (skipped — no host-config.yaml)"
    return
  fi

  local ci_json iface
  ci_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"
  if [ -z "$ci_json" ] || [ "$ci_json" = "{}" ]; then
    phase "phase 9: ecat-interface  (skipped — no cpuIsolation block)"
    info "the pre-phase prompt populates this on a TTY; non-interactive"
    info "runs must hand-edit $hc (see docs/internal/cpu-isolation.md) and re-run."
    return
  fi
  { read -r iface; } < <(cpusets_json_nic "$ci_json")
  if [ -z "$iface" ]; then
    phase "phase 9: ecat-interface  (skipped — cpuIsolation.nic.iface not set)"
    return
  fi
  phase "phase 9: ecat-interface (gates phase 10)"

  # --- Step 1: resolve target MAC --------------------------------------
  local mac="" sel_kind sel_value sel_index
  read -r sel_kind sel_value sel_index < <(_ecat_selector_fields "$ci_json")

  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$sel_kind" ]; then
      info "DRY-RUN  resolve MAC via selector: $sel_kind=$sel_value${sel_index:+ (index=$sel_index)}"
    else
      info "DRY-RUN  resolve MAC via interactive picker (TTY) and persist to host-config"
    fi
    info "DRY-RUN  if iface $iface already exists with that MAC, udev rule binds it, and .link file pins PHY -> no-op"
    info "DRY-RUN  else: write /etc/udev/rules.d/70-ecat.rules entry, write /etc/systemd/network/00-${iface}-phy.link, udevadm reload+trigger, wait for iface"
    return
  fi

  if [ -n "$sel_kind" ]; then
    case "$sel_kind" in
      mac)    mac="$(nic_resolve_target_mac --mac "$sel_value")" ;;
      pci)    mac="$(nic_resolve_target_mac --pci "$sel_value")" ;;
      driver) mac="$(nic_resolve_target_mac --driver "$sel_value" --index "$sel_index")" ;;
    esac
    if [ -z "$mac" ]; then
      fail "selector $sel_kind=$sel_value did not match any NIC"
      info "check 'ip -br link' output and update cpuIsolation.nic.selector in $hc"
      return
    fi
    pass "selector $sel_kind=$sel_value resolves to MAC $mac"
  else
    if [ ! -t 0 ] || [ ! -t 2 ]; then
      fail "no cpuIsolation.nic.selector and shell is not interactive"
      info "add a selector (mac/pci/driver+index) to $hc, or rerun on a TTY"
      return
    fi
    if ! mac="$(nic_resolve_target_mac_interactive "$iface")" || [ -z "$mac" ]; then
      fail "operator did not pick a NIC"
      return
    fi
    pass "operator picked MAC $mac via interactive picker"
    # Persist the choice as cpuIsolation.nic.selector.mac so the next
    # run is non-interactive.
    if _ecat_persist_selector_mac "$hc" "$ci_json" "$mac"; then
      pass "persisted selector.mac=$mac to $hc"
    else
      info "could not persist selector — next bootstrap will re-prompt"
    fi
  fi

  # --- Step 2: idempotency guard ---------------------------------------
  if nic_already_named "$iface" "$mac" \
     && nic_udev_rule_present "$iface" "$mac" \
     && nic_link_file_present "$iface" "$mac"; then
    pass "iface $iface already named, udev rule + .link file in place — no-op"
    return
  fi

  # --- Step 3: write rule ----------------------------------------------
  note "writing udev rule binding $iface -> $mac..."
  if ! nic_write_udev_rule "$iface" "$mac"; then
    fail "could not write /etc/udev/rules.d/70-ecat.rules"
    return
  fi
  pass "udev rule installed"

  # --- Step 4: write systemd .link file (PHY pinning) ------------------
  # EtherCAT slaves advertise only 100baseT/Half and don't auto-negotiate.
  # The .link file is applied by udevd on every device-add event,
  # independent of who manages L3 (networkd / NetworkManager / unmanaged).
  # This is what makes autoneg=off survive cable replug, driver reset,
  # and netplan apply — the only mechanism in the stack that does.
  local link_path
  link_path=$(nic_link_file_path "$iface")
  note "writing systemd .link file pinning $iface PHY (100M/full/autoneg-off)..."
  if ! nic_write_link_file "$iface" "$mac"; then
    fail "could not write $link_path"
    return
  fi
  pass ".link file installed at $link_path"

  # --- Step 5: apply --------------------------------------------------
  # nic_apply_iface handles all three cases: already correct (no-op),
  # current iface has the right MAC under a different name (in-kernel
  # rename), or hot-plug wait. The library's nic_apply_udev alone is
  # not enough — udevadm trigger --action=change does not re-fire
  # rename rules, only hotplug add does.
  note "applying iface $iface (in-kernel rename or udev hotplug-wait)..."
  if nic_apply_iface "$iface" "$mac"; then
    pass "iface $iface up"
  else
    fail "iface $iface did not appear / could not be renamed"
    info "check 'ip -br link' for the actual name + MAC, and"
    info "'journalctl -u systemd-udevd' for udev errors"
    return
  fi
}

# Echo three space-separated tokens to stdout: <kind> <value> <index>.
# kind is one of {mac, pci, driver} or empty when no selector is set.
# index is empty unless kind=driver. Used by ecat_interface to dispatch
# to the right nic_resolve_target_mac flag combination.
_ecat_selector_fields() {
  python3 - "$1" <<'PY' 2>/dev/null || echo ""
import json, sys
data = json.loads(sys.argv[1] or "{}")
sel = ((data.get("nic") or {}).get("selector") or {})
if sel.get("mac"):
    print(f"mac {sel['mac']} ")
elif sel.get("pci"):
    print(f"pci {sel['pci']} ")
elif sel.get("driver"):
    print(f"driver {sel['driver']} {sel.get('index', 0)}")
else:
    print("")
PY
}

# Splice cpuIsolation.nic.selector.mac into host-config.yaml after the
# operator picks a NIC interactively. Replaces any existing selector
# block. Returns 0 on success.
_ecat_persist_selector_mac() {
  local hc="$1" ci_json="$2" mac="$3"
  local merged
  merged="$(python3 - "$ci_json" "$mac" <<'PY'
import json, sys
d = json.loads(sys.argv[1] or "{}")
nic = d.get("nic") or {}
nic["selector"] = {"mac": sys.argv[2]}
d["nic"] = nic
print(json.dumps(d))
PY
)"
  _cpu_isolation_persist "$hc" "$merged"
}

# ---- phase 10: cpu-isolation (gates phase 12) --------------------------

# Carve isolated cpuset partitions out of the running kernel, pin the
# EtherCAT NIC's IRQs (optional), and persist via systemd. Runs BEFORE
# phase 12's dma-ethercat install because the .deb's systemd unit pins
# itself to the RT cores — if the partition isn't there yet, the unit
# starts unisolated.
#
# Host-config-driven. The cpuIsolation: block in host-config.yaml is
# the source of truth. The pre-phase prompt above (run before phase 9)
# normally populates the block on first bringup; the prompt here is a
# defensive fallback for runs that bypass the pre-phase (e.g., the
# operator answered N at the pre-phase prompt, or someone hand-rolled
# `--cpu-isolation` only without `--ecat-interface`). Only an explicit
# `enabled: false` skips the phase. See docs/internal/cpu-isolation.md for the
# schema and lifecycle.
#
# Idempotent: re-runs are safe. The vendored manage_cpusets.sh skips
# already-active partitions with matching CPUs; install-service and
# install-affinity-defaults overwrite their target files in place.
cpu_isolation() {
  if [ "$SKIP_CPU_ISOLATION" = 1 ]; then
    phase "phase 10: cpu-isolation  (skipped — --skip-cpu-isolation)"
    return
  fi

  # Read the cpuIsolation block.
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi
  if [ ! -r "$hc" ]; then
    phase "phase 10: cpu-isolation  (skipped — no host-config.yaml)"
    return
  fi
  local ci_json enabled
  ci_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"

  # Empty block? Default-on flow:
  #   - DRY_RUN: skip (don't mutate host-config in dry-run)
  #   - TTY    : prompt operator, persist, reload
  #   - else   : skip with a clear actionable message
  if [ "$ci_json" = "{}" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      phase "phase 10: cpu-isolation  (skipped — no cpuIsolation block, dry-run won't prompt)"
      return
    fi
    if [ -t 0 ] && [ -t 2 ]; then
      phase "phase 10: cpu-isolation (first-bringup setup)"
      if ! _cpu_isolation_prompt "$hc"; then
        fail "cpu-isolation interactive setup aborted"
        info "rerun and complete the prompts, or set cpuIsolation.enabled=false in $hc to opt out"
        return
      fi
      ci_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"
    else
      phase "phase 10: cpu-isolation  (skipped — no cpuIsolation block; non-interactive shell)"
      info "first bringup needs an interactive shell to configure CPU isolation,"
      info "OR hand-edit $hc to add a cpuIsolation: block (see docs/internal/cpu-isolation.md),"
      info "OR set cpuIsolation.enabled=false to opt out persistently."
      return
    fi
  fi

  # Block presence implies enabled-by-default — only an explicit
  # `enabled: false` opts out. Matches stacks.<name>.enabled semantics.
  enabled="$(cpusets_json_field "$ci_json" enabled)"
  if [ -n "$enabled" ] && [ "$enabled" != "true" ]; then
    phase "phase 10: cpu-isolation  (skipped — cpuIsolation.enabled=false)"
    return
  fi
  phase "phase 10: cpu-isolation (gates phase 12)"

  # Detect legacy single-core configs (cpuIsolation.nic.irqCore set,
  # but no top-level cpuIsolation.dmaRtCpu). These typically come from
  # bootstrap runs that pre-date the irqCore/dmaRtCpu split — the old
  # prompt persisted nic.rtCore only, validator translates it to
  # nic.irqCore for back-compat, and the env-write helper falls back to
  # using irqCore as DMA_RT_CPU. Net effect: NIC IRQs and the SOEM RT
  # loop end up co-located, defeating the whole point of distinct
  # cores. On a TTY we prompt for the missing dmaRtCpu; off-TTY we
  # fail loudly.
  local _ci_iface _ci_irq _ci_dma_rt
  { read -r _ci_iface; read -r _ci_irq; } < <(cpusets_json_nic "$ci_json")
  _ci_dma_rt="$(cpusets_json_dma_rt_cpu "$ci_json")"
  if [ -n "$_ci_irq" ] && [ -z "$_ci_dma_rt" ]; then
    info "host-config has nic.irqCore=$_ci_irq but no cpuIsolation.dmaRtCpu."
    info "for low-jitter EtherCAT the SOEM RT loop core SHOULD differ from"
    info "the NIC IRQ core — async interrupts can preempt the cyclic loop."
    if [ -t 0 ] && [ -t 2 ] && [ "$DRY_RUN" != 1 ]; then
      if ! _cpu_isolation_prompt_dma_rt_cpu "$hc" "$ci_json" "$_ci_irq"; then
        fail "operator declined to set dmaRtCpu — bootstrap would silently"
        info "co-locate IRQs and the RT loop. Re-run and pick a distinct core,"
        info "or hand-edit $hc to add 'dmaRtCpu: <core>' under cpuIsolation."
        return
      fi
      ci_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"
    else
      fail "cpuIsolation.dmaRtCpu missing and shell is not interactive"
      info "add 'dmaRtCpu: <core>' under cpuIsolation in $hc and re-run,"
      info "or rerun on a TTY to be prompted. To deliberately co-locate"
      info "(soft-RT only), set dmaRtCpu to the same value as nic.irqCore"
      info "— validator will warn but not fail."
      return
    fi
  fi

  # Sanity: ensure manage_cpusets is present (we still use ethercat-rt
  # for IRQ pin + governor lock + workqueue mask + boot-time service).
  if [ ! -x "$CPUSETS_SCRIPT" ]; then
    fail "$CPUSETS_SCRIPT not found or not executable"
    return
  fi

  # Validate the host-config has the fields the manage_cpusets subcommands
  # need before any side-effects. partitions[] populates /etc/cpusets.conf
  # in Step 1; dmaRtCpu drives nohz_full= in the cmdline migration.
  local isolcpus
  isolcpus="$(_cpu_isolation_partitions_union "$ci_json")"
  if [ -z "$isolcpus" ] || [ -z "$_ci_dma_rt" ]; then
    fail "cpuIsolation.partitions and cpuIsolation.dmaRtCpu are required"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  render $CPUSETS_CONF from cpuIsolation.partitions[]"
    info "DRY-RUN  apply cpuset partitions (cgroup-v2) covering cpus $isolcpus"
    info "DRY-RUN  install cpusets.service for boot persistence"
    info "DRY-RUN  migrate-cmdline --add-rt-flags  (adds isolcpus=managed_irq,$isolcpus,"
    info "DRY-RUN    nohz_full=$_ci_dma_rt, rcu_nocbs=$isolcpus, rcu_nocb_poll,"
    info "DRY-RUN    skew_tick=1, irqaffinity=<housekeeping>)"
    info "DRY-RUN  write systemd CPUAffinity drop-in (online − partitions − {0})"
    local _nic_iface _nic_irq
    { read -r _nic_iface; read -r _nic_irq; } < <(cpusets_json_nic "$ci_json")
    if [ -n "$_nic_iface" ] && [ -n "$_nic_irq" ]; then
      info "DRY-RUN  pin $_nic_iface IRQs to core $_nic_irq + governor lock + workqueue mask + boot service"
    fi
    info "DRY-RUN  warn REBOOT REQUIRED if cmdline changed"
    return
  fi

  # ---- Step 1: render /etc/cpusets.conf from host-config ----------------
  # Single source of truth for partition layout is cpuIsolation.partitions[]
  # in host-config.yaml. The lib helper renders [name]/cpus= INI blocks
  # that manage_cpusets.sh apply consumes verbatim.
  if cpusets_render_conf "$ci_json" >/dev/null; then
    pass "rendered $CPUSETS_CONF from cpuIsolation.partitions"
  else
    fail "failed to render $CPUSETS_CONF"
    return
  fi

  # ---- Step 2a: reconcile orphan partitions -----------------------------
  # manage_cpusets.sh apply creates/updates partitions named in the config
  # but does NOT remove ones absent from it — applied partitions whose
  # cpus overlap an orphan cause apply to fail. This matters on robots
  # bootstrapped before the partitions[].name field was honoured: they
  # carry a legacy "ecat-cmdline" partition that overlaps with whatever
  # name host-config now declares (e.g. "ecat1"). Sweep any state-file
  # entry whose name isn't in the desired list before apply runs.
  local state_file="${MANAGE_CPUSETS_STATE_FILE:-/var/lib/manage_cpusets/state}"
  if [ -r "$state_file" ]; then
    local desired_names existing_name
    desired_names="$(cpusets_json_partition_names "$ci_json")"
    while IFS='|' read -r existing_name _ _; do
      [ -z "$existing_name" ] && continue
      if ! printf '%s\n' "$desired_names" | grep -Fxq -- "$existing_name"; then
        note "removing orphan partition '$existing_name' (not in cpuIsolation.partitions)..."
        cpusets_run remove "$existing_name" >/dev/null 2>&1 || \
          warn "manage_cpusets.sh remove $existing_name failed (continuing)"
      fi
    done < "$state_file"
  fi

  # ---- Step 2: apply cpuset partitions (cgroup-v2) ----------------------
  # apply creates new partitions and no-ops on already-matching cpus.
  # --yes skips the isolcpus= overlap prompt; we migrate the cmdline to
  # the managed_irq form in step 4.
  note "applying cpuset partitions from $CPUSETS_CONF..."
  if cpusets_run apply "$CPUSETS_CONF" --yes; then
    pass "cpuset partitions applied"
  else
    fail "manage_cpusets.sh apply failed"
    return
  fi

  # ---- Step 3: install cpusets.service for boot persistence -------------
  # Without this, the cgroup-v2 partition created by 'apply' disappears
  # at the next reboot. install-service is idempotent (overwrites the
  # same files on re-run). Redirect verbose stdout — operators don't
  # need to re-see the install paths on every bootstrap.
  if cpusets_run install-service "$CPUSETS_CONF" >/dev/null; then
    pass "cpusets.service installed and enabled"
  else
    fail "manage_cpusets.sh install-service failed"
    return
  fi

  # Note: per-partition slice units are rendered by `manage_cpusets.sh apply`
  # in step 2 above (since FIR-319). The slice cgroup IS the partition: the
  # apply subcommand writes the slice unit, starts it, then sets
  # cpuset.cpus.exclusive and cpuset.cpus.partition=isolated on the slice's
  # cgroup. Earlier versions of this phase rendered the slice here
  # separately, which led to a sibling-cgroup conflict with the partition.

  # ---- Step 4: kernel cmdline migration --------------------------------
  # Delegates to manage_cpusets.sh migrate-cmdline so the bootstrap and
  # standalone operator workflows share a single cmdline editor. Adds
  # rcu_nocb_poll, skew_tick=1, irqaffinity=<housekeeping>, and
  # isolcpus=managed_irq,<partition-cpus> (the only knob that keeps
  # driver-managed PCIe/MSI-X vectors off isolated cores). Strips legacy
  # plain isolcpus=<cpus> if present — scheduler isolation comes from
  # the cgroup-v2 partition created in step 2, not the cmdline.
  local cmdline_changed=0
  local migrate_out migrate_rc
  migrate_out="$(cpusets_run migrate-cmdline --add-rt-flags --yes 2>&1)"
  migrate_rc=$?
  printf '%s\n' "$migrate_out"
  if [ $migrate_rc -ne 0 ]; then
    fail "manage_cpusets.sh migrate-cmdline failed"
    return
  fi
  if printf '%s' "$migrate_out" | grep -q "No change needed"; then
    skip "kernel cmdline already at desired state"
  else
    cmdline_changed=1
    pass "kernel cmdline updated (REBOOT REQUIRED for full effect)"
  fi

  # ---- Step 5: systemd CPUAffinity drop-in ------------------------------
  # Compute housekeeping = (online cpus) − (partition cpus) − {0}.
  # cpu 0 is dropped explicitly so kernel housekeeping (kworker/0,
  # ksoftirqd/0, RCU callback workers, default IRQs) gets a quiet
  # cpu without competing with userspace services.
  local install_aff cpuaffinity_value
  install_aff="$(cpusets_json_field "$ci_json" installAffinityDefaults)"
  if [ -z "$install_aff" ] || [ "$install_aff" = "true" ]; then
    cpuaffinity_value="$(_compute_systemd_cpuaffinity "$ci_json")"
    if [ -n "$cpuaffinity_value" ]; then
      _install_cpuaffinity_dropin "$cpuaffinity_value" || true
    else
      fail "could not compute CPUAffinity value (no online cpus left after exclusions)"
    fi
  else
    skip "cpuIsolation.installAffinityDefaults=false — leaving systemd defaults alone"
  fi

  # ---- Step 6: NIC IRQ pin + governor + workqueue + boot service -------
  # Resolve which declared partition contains nic.irqCore — that's the
  # partition ethercat-rt anchors to. Replaces the legacy hardcoded
  # "ecat-cmdline" partition name so partitions[].name in host-config
  # is the source of truth.
  local nic_iface nic_irq
  { read -r nic_iface; read -r nic_irq; } < <(cpusets_json_nic "$ci_json")
  if [ -n "$nic_iface" ] && [ -n "$nic_irq" ]; then
    local part_name
    part_name="$(_cpu_isolation_partition_for_cpu "$ci_json" "$nic_irq")"
    if [ -z "$part_name" ]; then
      fail "no cpuIsolation.partitions[] entry covers nic.irqCore=$nic_irq"
      return
    fi
    note "pinning $nic_iface IRQs to core $nic_irq (partition '$part_name')..."
    if cpusets_run ethercat-rt "$part_name" --nic "$nic_iface" --rt-core "$nic_irq"; then
      pass "ethercat-rt configured: $nic_iface IRQs on core $nic_irq"
    else
      fail "manage_cpusets.sh ethercat-rt failed"
    fi
  else
    skip "cpuIsolation.nic not set — skipping NIC IRQ pinning"
  fi

  # ---- Step 7: reboot marker --------------------------------------------
  if [ "$cmdline_changed" = 1 ]; then
    mkdir -p "$(dirname "$CPU_ISOLATION_REBOOT_MARKER")"
    printf 'cmdline updated at %s — reboot to pick it up\n' \
      "$(date -u +%FT%TZ)" > "$CPU_ISOLATION_REBOOT_MARKER"
    info ""
    info "════════════════════════════════════════════════════════════"
    info "  REBOOT REQUIRED for kernel cmdline changes to take effect"
    info "════════════════════════════════════════════════════════════"
    info ""
  fi

  # Clear stale reboot marker if the live cmdline already matches. Check
  # the new form (isolcpus=managed_irq,<cpus>) since that's what
  # migrate-cmdline emits now.
  if [ -f "$CPU_ISOLATION_REBOOT_MARKER" ] && \
     grep -q "isolcpus=managed_irq,$isolcpus" /proc/cmdline 2>/dev/null && \
     grep -q "nohz_full=$_ci_dma_rt" /proc/cmdline 2>/dev/null; then
    rm -f "$CPU_ISOLATION_REBOOT_MARKER"
    info "cleared stale reboot marker — cmdline already migrated"
  fi
}

# ---------- helpers for cpu_isolation -----------------------------------

# Echo the union of cpuIsolation.partitions[].cpus as a kernel cpu-list
# (e.g. "11-13"). Empty when no partitions declared.
_cpu_isolation_partitions_union() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
data = json.loads(sys.argv[1] or "{}")
def expand(spec):
    out = set()
    for part in spec.split(","):
        if "-" in part:
            lo, hi = part.split("-", 1); out.update(range(int(lo), int(hi)+1))
        else: out.add(int(part))
    return out
def compress(cpus):
    if not cpus: return ""
    s = sorted(cpus)
    ranges, lo = [], s[0]
    for i, c in enumerate(s):
        if i+1 == len(s) or s[i+1] != c+1:
            ranges.append((lo, c)); lo = s[i+1] if i+1 < len(s) else None
    return ",".join(f"{a}" if a==b else f"{a}-{b}" for a,b in ranges)
acc = set()
for p in (data.get("partitions") or []):
    cpus = p.get("cpus", "")
    if isinstance(cpus, str): acc |= expand(cpus)
print(compress(acc))
PY
}

# Echo the name of the cpuIsolation.partitions[] entry whose `cpus`
# range contains the given cpu, or empty string if no entry matches.
# Used to resolve which partition ethercat-rt should anchor to from
# cpuIsolation.nic.irqCore, replacing the historical hardcoded
# "ecat-cmdline" partition name.
_cpu_isolation_partition_for_cpu() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
data = json.loads(sys.argv[1] or "{}")
try:
    target = int(sys.argv[2])
except (ValueError, IndexError):
    sys.exit(0)
def expand(spec):
    out = set()
    for part in spec.split(","):
        if "-" in part:
            lo, hi = part.split("-", 1); out.update(range(int(lo), int(hi)+1))
        else: out.add(int(part))
    return out
for p in (data.get("partitions") or []):
    cpus = p.get("cpus", "")
    if not isinstance(cpus, str): continue
    if target in expand(cpus):
        print(p.get("name", "")); break
PY
}

# Echo the systemd CPUAffinity= value (online cpus minus partition cpus
# minus cpu 0). Empty if the result would be empty.
_compute_systemd_cpuaffinity() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
data = json.loads(sys.argv[1] or "{}")
def expand(spec):
    out = set()
    for part in spec.split(","):
        if "-" in part:
            lo, hi = part.split("-", 1); out.update(range(int(lo), int(hi)+1))
        else: out.add(int(part))
    return out
def compress(cpus):
    if not cpus: return ""
    s = sorted(cpus)
    ranges, lo = [], s[0]
    for i, c in enumerate(s):
        if i+1 == len(s) or s[i+1] != c+1:
            ranges.append((lo, c)); lo = s[i+1] if i+1 < len(s) else None
    return ",".join(f"{a}" if a==b else f"{a}-{b}" for a,b in ranges)
try:
    online = expand(open("/sys/devices/system/cpu/online").read().strip())
except Exception:
    online = set()
managed = set()
for p in (data.get("partitions") or []):
    cpus = p.get("cpus", "")
    if isinstance(cpus, str): managed |= expand(cpus)
result = online - managed - {0}
print(compress(result))
PY
}

# Write /etc/systemd/system.conf.d/cpuaffinity.conf with the given
# CPUAffinity value. Idempotent (cmp + skip), runs daemon-reexec on
# change.
_install_cpuaffinity_dropin() {
  local value="$1"
  local dst=/etc/systemd/system.conf.d/cpuaffinity.conf
  mkdir -p "$(dirname "$dst")"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by scripts/bootstrap-robot.sh phase 10 (cpu-isolation).
# Restricts default CPU affinity for systemd-spawned services to the
# k8s pool (online cpus minus host-RT partitions minus cpu 0). cpu 0
# is left for kernel housekeeping (kworker/0, ksoftirqd/0, default
# IRQs); the host-RT partitions are governed by isolcpus= in the
# kernel cmdline. Services that legitimately need to run on cpu 0
# or the isolated cores must override via their own CPUAffinity= or
# AllowedCPUs=.
[Manager]
CPUAffinity=$value
EOF
  if cmp -s "$tmp" "$dst" 2>/dev/null; then
    skip "systemd CPUAffinity drop-in already at CPUAffinity=$value"
    rm -f "$tmp"
    return 0
  fi
  install -m 0644 "$tmp" "$dst"
  rm -f "$tmp"
  pass "wrote $dst (CPUAffinity=$value)"
  systemctl daemon-reexec || true
  return 0
}

# ---- phase 11: log management ----------------------------------------
#
# Caps journald + rsyslog disk usage via drop-in config files. Real
# incident: a Thor robot filled its 937 GB root partition with a single
# 793 GB /var/log/syslog because the stock /etc/logrotate.d/rsyslog
# specifies `weekly` rotation with no `maxsize`. A second incident
# (hw-thor01, 745 GB syslog) was caused by logrotate not being
# installed at all — the drop-in below is inert without the binary.
# Bootstrap writes:
#
#   /etc/systemd/journald.conf.d/phantomos.conf  (SystemMaxUse, SystemMaxFileSize)
#   /etc/logrotate.d/phantomos-syslog            (sorts after rsyslog → wins)
#   /etc/systemd/system/logrotate.timer.d/override.conf  (hourly, not daily)
#
# `apt-get install logrotate` runs first so the package is guaranteed
# present. The upstream config files are left untouched so dpkg upgrades
# don't trigger 'modified config' prompts. logManagement.enabled: false
# removes our drop-ins and leaves the host on stock behavior.

log_management() {
  if [ "${SKIP_LOG_MANAGEMENT:-0}" = 1 ]; then
    phase "phase 11: log management  (skipped — --skip-log-management)"
    return
  fi
  phase "phase 11: log management"

  local hc_path="/etc/phantomos/host-config.yaml"
  if [ ! -f "$hc_path" ]; then
    hc_path="$REPO_ROOT/host-config.yaml"
  fi

  local lm_json
  if [ -f "$hc_path" ]; then
    if ! lm_json=$(python3 "$HOST_CONFIG_HELPER" "$hc_path" get-log-management-json 2>/dev/null); then
      fail "host-config get-log-management-json"
      return
    fi
  else
    info "no host-config.yaml at $hc_path — applying defaults"
    lm_json='{"enabled":true,"journald":{"systemMaxUse":"2G","systemMaxFileSize":"100M"},"rsyslog":{"maxsize":"500M","rotate":7,"frequency":"daily","compress":true}}'
  fi

  if [ "$(printf '%s' "$lm_json" | jq -r '.enabled')" = "false" ]; then
    info "logManagement.enabled=false — removing any prior phantomos drop-ins"
    if [ "$DRY_RUN" = 0 ]; then
      rm -f /etc/systemd/journald.conf.d/phantomos.conf
      rm -f /etc/logrotate.d/phantomos-syslog
      systemctl restart systemd-journald 2>/dev/null || true
    fi
    pass "log-management disabled"
    return
  fi

  local jd_use jd_file rs_size rs_rot rs_freq rs_compress
  jd_use=$(printf '%s' "$lm_json" | jq -r '.journald.systemMaxUse')
  jd_file=$(printf '%s' "$lm_json" | jq -r '.journald.systemMaxFileSize')
  rs_size=$(printf '%s' "$lm_json" | jq -r '.rsyslog.maxsize')
  rs_rot=$(printf '%s' "$lm_json" | jq -r '.rsyslog.rotate')
  rs_freq=$(printf '%s' "$lm_json" | jq -r '.rsyslog.frequency')
  rs_compress=$(printf '%s' "$lm_json" | jq -r '.rsyslog.compress')

  # --- journald drop-in ---
  local jd_target="/etc/systemd/journald.conf.d/phantomos.conf"
  local jd_tmp; jd_tmp=$(mktemp)
  cat >"$jd_tmp" <<EOF
# Managed by scripts/bootstrap-robot.sh phase log-management.
# Caps journald disk usage. /etc/systemd/journald.conf is left
# untouched; this drop-in overrides only the keys we care about.
[Journal]
SystemMaxUse=${jd_use}
SystemMaxFileSize=${jd_file}
EOF
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  would install $jd_target (SystemMaxUse=$jd_use, SystemMaxFileSize=$jd_file)"
    rm -f "$jd_tmp"
  elif [ -f "$jd_target" ] && cmp -s "$jd_tmp" "$jd_target"; then
    info "journald drop-in unchanged"
    rm -f "$jd_tmp"
  else
    install -D -m 0644 "$jd_tmp" "$jd_target"
    rm -f "$jd_tmp"
    if systemctl restart systemd-journald; then
      info "journald restarted with SystemMaxUse=$jd_use SystemMaxFileSize=$jd_file"
    else
      fail "systemctl restart systemd-journald"
      return
    fi
  fi

  # --- logrotate drop-in ---
  # Conditional: only meaningful on hosts where rsyslog is actually
  # writing /var/log/syslog. Ubuntu 24.04 minimal is often journald-
  # only — no rsyslog package, no /var/log/syslog, no rsyslog-rotate
  # script. Writing a logrotate stanza referencing those would just
  # noise up `logrotate --debug`. Detect and skip cleanly.
  local lr_target="/etc/logrotate.d/phantomos-syslog"
  local lr_timer_override="/etc/systemd/system/logrotate.timer.d/override.conf"
  local rsyslog_present=0
  if [ -f /usr/lib/rsyslog/rsyslog-rotate ] || command -v rsyslogd >/dev/null 2>&1; then
    rsyslog_present=1
  fi

  if [ "$rsyslog_present" = 0 ]; then
    # Clean up any prior phantomos-syslog drop-in that no longer has a
    # backing rsyslog install (e.g. operator removed the package).
    if [ "$DRY_RUN" = 0 ] && [ -f "$lr_target" ]; then
      rm -f "$lr_target"
      info "removed stale $lr_target (rsyslog no longer installed)"
    else
      info "rsyslog not installed; skipping logrotate drop-in (journald handles all logs here)"
    fi
    if [ "$DRY_RUN" = 0 ] && [ -f "$lr_timer_override" ]; then
      rm -f "$lr_timer_override"
      systemctl daemon-reload
      systemctl restart logrotate.timer 2>/dev/null || true
      info "removed stale $lr_timer_override (rsyslog no longer installed)"
    fi
  else
    # Ensure the logrotate package is actually installed. The drop-in
    # we write here is inert without the logrotate binary + its systemd
    # timer; we have seen a host with rsyslog present but logrotate
    # absent, where /var/log/syslog grew to 745 GB before the disk filled.
    if ! command -v logrotate >/dev/null 2>&1; then
      if [ "$DRY_RUN" = 1 ]; then
        info "DRY-RUN  would apt-get install logrotate (missing)"
      else
        info "logrotate not installed — installing"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate >/dev/null 2>&1; then
          fail "apt-get install logrotate"
          return
        fi
      fi
    fi

    local lr_tmp; lr_tmp=$(mktemp)
    local compress_block
    if [ "$rs_compress" = "true" ]; then
      compress_block=$'    compress\n    delaycompress'
    else
      compress_block="    nocompress"
    fi
    cat >"$lr_tmp" <<EOF
# Managed by scripts/bootstrap-robot.sh phase log-management.
# Sorts after /etc/logrotate.d/rsyslog so this stanza wins.
/var/log/syslog
{
    rotate ${rs_rot}
    ${rs_freq}
    maxsize ${rs_size}
    missingok
    notifempty
${compress_block}
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  would install $lr_target (maxsize=$rs_size, rotate=$rs_rot, $rs_freq)"
      rm -f "$lr_tmp"
    elif [ -f "$lr_target" ] && cmp -s "$lr_tmp" "$lr_target"; then
      info "logrotate drop-in unchanged"
      rm -f "$lr_tmp"
    else
      install -D -m 0644 "$lr_tmp" "$lr_target"
      rm -f "$lr_tmp"
      info "logrotate drop-in installed (maxsize=$rs_size rotate=$rs_rot $rs_freq)"
    fi

    # Override the upstream daily logrotate timer to fire hourly. The
    # ${rs_size} maxsize cap only takes effect when logrotate actually
    # runs — and /var/log/syslog can grow many GB/hour under a warning
    # storm. Hourly gives the cap a chance to enforce before the disk
    # fills. Idempotent: drop-in is rewritten only if its content changed.
    local lr_timer_tmp; lr_timer_tmp=$(mktemp)
    cat >"$lr_timer_tmp" <<'EOF'
# Managed by scripts/bootstrap-robot.sh phase log-management.
# Override the upstream daily schedule so the rsyslog `maxsize` cap can
# actually enforce under high-rate log spam.
[Timer]
OnCalendar=
OnCalendar=hourly
AccuracySec=5min
EOF
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  would install $lr_timer_override (hourly)"
      rm -f "$lr_timer_tmp"
    elif [ -f "$lr_timer_override" ] && cmp -s "$lr_timer_tmp" "$lr_timer_override"; then
      info "logrotate.timer override unchanged"
      rm -f "$lr_timer_tmp"
    else
      install -D -m 0644 "$lr_timer_tmp" "$lr_timer_override"
      rm -f "$lr_timer_tmp"
      systemctl daemon-reload
      systemctl restart logrotate.timer 2>/dev/null || true
      info "logrotate.timer override installed (hourly)"
    fi
  fi

  # --- validate ---
  if [ "$DRY_RUN" = 0 ]; then
    if ! journalctl --header --no-pager >/dev/null 2>&1; then
      fail "journalctl --header failed after restart"
      return
    fi
    # Logrotate validation is informational — `logrotate --debug` can
    # exit non-zero for environmental reasons (missing /var/log/syslog
    # despite `missingok`, postrotate-script path quirks, etc.) even
    # when the stanza itself is fine. The file is still installed; the
    # rotation will work the next time logrotate runs. Surface the
    # warning so the operator can investigate, but don't halt bootstrap.
    if [ "$rsyslog_present" = 1 ] && command -v logrotate >/dev/null 2>&1 && [ -f "$lr_target" ]; then
      local lr_err
      if ! lr_err=$(logrotate --debug "$lr_target" 2>&1 >/dev/null); then
        info "logrotate --debug reported issues for $lr_target (drop-in installed anyway):"
        printf '%s\n' "$lr_err" | sed 's/^/    logrotate: /' >&2
      fi
    fi
  fi

  if [ "$rsyslog_present" = 1 ]; then
    pass "log-management configured (journald: ${jd_use}/${jd_file}, syslog: ${rs_size}/${rs_rot}x${rs_freq})"
  else
    pass "log-management configured (journald: ${jd_use}/${jd_file}; rsyslog absent — logrotate skipped)"
  fi
}

# ---- phase 12: install dma-ethercat (gates phase 13) -------------------

# Install the dma-ethercat .deb baked into the foundationbot/dma-ethercat
# container image, then enable+start the bare-metal service. Runs strictly
# BEFORE phase 13 (gitops) — the realtime stack must be up before
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
    phase "phase 12: install dma-ethercat  (skipped — --skip-ethercat-install)"
    return
  fi
  phase "phase 12: install dma-ethercat (gates phase 13)"

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

  # Resolve the full image ref via the new container-keyed schema.
  # Operators write `images.dma-ethercat.image: <repo:tag>`; we plug
  # the whole thing into the Job template (replacing the
  # `foundationbot/dma-ethercat:PLACEHOLDER` placeholder), so swapping
  # to a private registry just works.
  local image_ref
  image_ref="$(python3 "$HOST_CONFIG_HELPER" "$hc" \
                 get-image-for-container dma-ethercat 2>/dev/null || true)"
  if [ -z "$image_ref" ]; then
    fail "host-config.yaml has no images.dma-ethercat.image entry"
    ethercat_die "add 'images.dma-ethercat.image: foundationbot/dma-ethercat:<tag>' to host-config.yaml and re-run"
  fi
  pass "resolved dma-ethercat image: $image_ref"

  # Render the Job manifest (sed-substitute PLACEHOLDER -> tag).
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  render $DMA_ETHERCAT_TEMPLATE -> $DMA_ETHERCAT_RENDERED  (image=$image_ref)"
    info "DRY-RUN  kubectl create ns phantom (if missing)"
    info "DRY-RUN  kubectl -n phantom delete job dma-ethercat-installer --ignore-not-found"
    info "DRY-RUN  wait node Ready + coredns rollout (CNI gate before applying the Job)"
    info "DRY-RUN  kubectl apply -f $DMA_ETHERCAT_RENDERED"
    info "DRY-RUN  kubectl -n phantom wait --for=condition=complete job/dma-ethercat-installer (10min budget, transient-tolerant)"
    info "DRY-RUN  dpkg -i /var/lib/dma-ethercat-installer/dma-ethercat-*.deb"
    info "DRY-RUN  dpkg -i /var/lib/dma-ethercat-installer/mk2-debug-tui_*.deb  (if baked in; non-fatal)"
    info "DRY-RUN  resolve+write DMA_CONFIG, INTERFACE, DMA_CPU_AFFINITY, DMA_RT_CPU into $DMA_ETHERCAT_ENV_FILE"
    info "DRY-RUN  systemctl enable --now dma-ethercat.service"
    return
  fi

  mkdir -p "$(dirname "$DMA_ETHERCAT_RENDERED")"
  sed -e "s#foundationbot/dma-ethercat:PLACEHOLDER#$image_ref#" \
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

  # Gate on cluster networking before applying the Job. On a fresh bootstrap
  # the node/CNI IPAM can briefly lag; the installer pod's first sandbox then
  # fails with "no IP ranges specified" and the Job is delayed past the wait
  # below. Waiting for the node Ready + coredns rollout (which proves pods can
  # get IPs) lets the pod schedule cleanly on its first try.
  note "waiting for node + CNI networking to be Ready..."
  if "${KUBECTL[@]}" wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1; then
    pass "node Ready"
  else
    info "node not Ready within 180s — proceeding; the Job wait below tolerates transient CNI"
  fi
  if "${KUBECTL[@]}" -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1; then
    pass "CNI networking Ready (coredns rolled out)"
  else
    info "coredns not Available within 120s — proceeding; transient CNI is tolerated below"
  fi

  note "applying installer manifest..."
  if "${KUBECTL[@]}" apply -f "$DMA_ETHERCAT_RENDERED" >/dev/null; then
    pass "installer Job applied"
  else
    fail "kubectl apply -f $DMA_ETHERCAT_RENDERED"
    ethercat_die "could not apply installer Job — check rendered manifest at $DMA_ETHERCAT_RENDERED"
  fi

  # Wait for the installer Job to complete. A `kubectl wait` timeout is NOT a
  # failure — the Job may still be retrying a transient (e.g. an early CNI
  # "no IP ranges" sandbox error that clears on the pod's next attempt). So
  # poll in 60s slices up to a 10min budget: succeed on the `complete`
  # condition, bail early ONLY on a real `failed` condition (backoffLimit
  # exhausted), otherwise keep waiting.
  note "waiting up to 10min for installer Job to reach Complete..."
  local _job_done=0 _job_failed=0 _waited=0
  while [ "$_waited" -lt 600 ]; do
    if "${KUBECTL[@]}" -n phantom wait --for=condition=complete --timeout=60s \
         job/dma-ethercat-installer >/dev/null 2>&1; then
      _job_done=1; break
    fi
    if "${KUBECTL[@]}" -n phantom wait --for=condition=failed --timeout=1s \
         job/dma-ethercat-installer >/dev/null 2>&1; then
      _job_failed=1; break
    fi
    _waited=$((_waited + 60))
    info "installer Job still running (${_waited}s elapsed of 600s budget)..."
  done
  if [ "$_job_done" = 1 ]; then
    pass "installer Job Complete"
  else
    local jstat
    jstat=$("${KUBECTL[@]}" -n phantom get job dma-ethercat-installer -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}' 2>/dev/null || true)
    if [ "$_job_failed" = 1 ]; then
      fail "installer Job FAILED (status: ${jstat:-unknown})"
    else
      fail "installer Job did not Complete within 10min (status: ${jstat:-unknown})"
    fi
    info "Job events:"
    "${KUBECTL[@]}" -n phantom describe job dma-ethercat-installer 2>&1 \
      | sed -n '/Events:/,$p' | sed 's/^/      /' || true
    info "pod logs:"
    "${KUBECTL[@]}" -n phantom logs -l app=dma-ethercat-installer --tail=50 2>&1 | sed 's/^/      /' || true
    ethercat_die "installer Job did not complete — check the events/logs above (CNI sandbox, image pull, or the Job's cp step)"
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

  # mk2-debug-tui: optional debug TUI baked into the same image (arm64
  # only — see the dma-ethercat image's ci/fetch_mk2_debug_tui.sh and the
  # installer Job's best-effort copy). NON-FATAL by design: it's a debug
  # tool, not part of the realtime control path, so a missing/failed
  # install must never ethercat_die and wedge the fleet bringup.
  local tui_deb
  tui_deb=$(ls -1t /var/lib/dma-ethercat-installer/mk2-debug-tui_*.deb 2>/dev/null | head -1 || true)
  if [ -z "$tui_deb" ]; then
    info "no mk2-debug-tui .deb baked into image — skipping (expected on amd64)"
  else
    note "installing mk2-debug-tui: $(basename "$tui_deb")"
    if dpkg -i "$tui_deb"; then
      pass "dpkg -i $(basename "$tui_deb")"
    else
      warn "dpkg -i $(basename "$tui_deb") failed — continuing (debug tool, non-fatal)"
    fi
  fi

  # Resolve DMA_CONFIG and pin it in /etc/dma/dma-ethercat.env. The .deb
  # ships a default DMA_CONFIG that is correct only for the package's
  # canonical robot — every other robot needs an override. Order:
  #   1. host-config dmaEthercat.configSet ->
  #        /usr/share/dma-ethercat/config/<configSet>/<robot>.json
  #   2. auto-detect by robot name:
  #        /usr/share/dma-ethercat/config/<robot>.json
  #        /usr/share/dma-ethercat/config/<robot>/<robot>.json
  #   3. neither -> halt with instructions to set dmaEthercat.configSet.
  configure_dma_ethercat_env "$hc"

  # Place dma-ethercat.service in the cpuset partition's slice (rendered
  # in phase 10 step 3b) so it can actually run on the isolated cpus.
  # Without this, the service inherits system.slice's housekeeping
  # cpuset.cpus ceiling and the unit's ExecStart `taskset -c 11-13`
  # fails with EINVAL because the cgroup-v2 cpuset ceiling forbids it.
  # The slice name is resolved from cpuIsolation.partitions[] — find
  # the partition whose cpus range contains nic.irqCore (matches
  # ethercat-rt's partition lookup in phase 10 step 6).
  local _ci_json _nic_irq _slice_name
  _ci_json="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"
  { read -r _ ; read -r _nic_irq; } < <(cpusets_json_nic "$_ci_json")
  if [ -n "$_nic_irq" ]; then
    _slice_name="$(_cpu_isolation_partition_for_cpu "$_ci_json" "$_nic_irq")"
    if [ -n "$_slice_name" ]; then
      if cpusets_render_service_slice_dropin dma-ethercat.service "$_slice_name" >/dev/null; then
        systemctl daemon-reload
        pass "dma-ethercat.service drop-in: Slice=${_slice_name}.slice"
      else
        warn "failed to render dma-ethercat slice drop-in (service may fail to start on isolated cpus)"
      fi
    else
      warn "no cpuIsolation.partitions[] entry covers nic.irqCore=$_nic_irq — skipping dma-ethercat slice drop-in"
    fi
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

# Resolve the per-robot DMA_CONFIG path and write it to
# /etc/dma/dma-ethercat.env. The env file is a dpkg conffile, so we
# preserve every line except DMA_CONFIG=. Path resolution uses the
# robot id ($ROBOT) and, optionally, host-config dmaEthercat.configSet.
DMA_ETHERCAT_ENV_FILE="${DMA_ETHERCAT_ENV_FILE:-/etc/dma/dma-ethercat.env}"
DMA_ETHERCAT_CONFIG_DIR="${DMA_ETHERCAT_CONFIG_DIR:-/usr/share/dma-ethercat/config}"

# Interactive picker for DMA config JSON. Walks
# DMA_ETHERCAT_CONFIG_DIR to depth 2, lists every *.json, asks the
# operator to pick by number, echoes the absolute path on stdout.
# Returns non-zero on EOF, invalid input, or no .json files found —
# all prompt UI goes to stderr so stdout is the result channel.
_dma_ethercat_prompt_for_config() {
  local robot="$1"
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    find "$DMA_ETHERCAT_CONFIG_DIR" -maxdepth 2 -type f -name '*.json' \
      2>/dev/null | sort
  )
  if [ "${#files[@]}" -eq 0 ]; then
    fail "no .json files under $DMA_ETHERCAT_CONFIG_DIR" >&2
    return 1
  fi

  {
    printf '\n'
    printf '  no auto-match for robot %q. pick a hardware config:\n' "$robot"
    printf '\n'
    local i path rel
    for i in "${!files[@]}"; do
      path="${files[$i]}"
      rel="${path#"$DMA_ETHERCAT_CONFIG_DIR"/}"
      printf '    %3d) %s\n' "$((i+1))" "$rel"
    done
    printf '\n'
  } >&2

  local choice
  printf '  selection [1-%d]: ' "${#files[@]}" >&2
  if ! IFS= read -r choice </dev/tty; then
    fail "no input on /dev/tty" >&2
    return 1
  fi
  case "$choice" in
    ''|*[!0-9]*) fail "not a number: $choice" >&2; return 1 ;;
  esac
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
    fail "out of range: $choice" >&2
    return 1
  fi
  printf '%s\n' "${files[$((choice-1))]}"
}

# Interactive setup for the cpuIsolation: block when host-config.yaml
# doesn't have one yet. Persists the answers back to host-config.yaml
# so re-runs are non-interactive. Returns 0 when the block was written
# and validates; returns 1 on operator opt-out, EOF, or validation
# failure (the caller skips the phase in those cases).
#
# Prompts (with sensible defaults):
#   1. enable now? — N writes `enabled: false` and returns 1
#   2. partition cpus      (default 11-13)
#   3. partition name      (default ecat)
#   4. NIC iface           (empty = skip NIC pinning)
#   5. NIC IRQ core        (default = first cpu of partition)
#   6. SOEM RT loop core   (default = a different cpu in the partition)
#   7. installAffinityDefaults  (default Y)
#   (Kernel cmdline editing is always-on under RFC 0004 — no toggle.)
_cpu_isolation_prompt() {
  local hc="$1"

  {
    printf '\n  CPU isolation carves cpuset partitions for the EtherCAT realtime\n'
    printf '  control loop. Required for production robots — answer the prompts\n'
    printf '  below to populate cpuIsolation: in %s.\n' "$hc"
    printf '  See docs/internal/cpu-isolation.md for the full schema.\n\n'
  } >&2

  local ans
  printf '  configure CPU isolation now? [Y/n]: ' >&2
  IFS= read -r ans </dev/tty || return 1
  case "${ans,,}" in
    n|no)
      if _cpu_isolation_persist "$hc" '{"enabled": false}'; then
        info "wrote cpuIsolation.enabled=false to $hc — phase will skip on re-runs"
      fi
      return 1
      ;;
  esac

  local partition_cpus partition_name nic_iface nic_irq dma_rt_cpu aff_ans mig_ans
  while :; do
    printf '  partition cpus (e.g. 11-13, 10,12-13) [11-13]: ' >&2
    IFS= read -r partition_cpus </dev/tty || return 1
    [ -z "$partition_cpus" ] && partition_cpus="11-13"
    if printf '%s' "$partition_cpus" | grep -Eq '^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$'; then
      break
    fi
    printf '    invalid — must match kernel cpu-list syntax\n' >&2
  done

  printf '  partition name [ecat]: ' >&2
  IFS= read -r partition_name </dev/tty || return 1
  [ -z "$partition_name" ] && partition_name="ecat"

  printf '  EtherCAT NIC interface (empty to skip NIC pinning) [ecat0]: ' >&2
  IFS= read -r nic_iface </dev/tty || return 1
  if [ -z "$nic_iface" ]; then
    # Empty input means use default. Operators who really want "no nic"
    # can hand-edit later — most robots want the NIC pinned.
    nic_iface="ecat0"
  fi

  # If the chosen iface isn't currently visible to the kernel, show a
  # list of real interfaces and let the operator pick one. Common case:
  # `ecat0` doesn't exist yet because phase 9's udev rename hasn't run
  # — phase 9 will create it on the next bootstrap. Operators can keep
  # the default (rename later) or pick a real interface to use directly.
  if ! ip link show dev "$nic_iface" >/dev/null 2>&1; then
    printf '\n  iface "%s" is not present on this host. Available interfaces:\n' "$nic_iface" >&2
    local _ifname _imac _istate _i=0
    local -a _iface_names=()
    while IFS=$'\t' read -r _ifname _imac _istate; do
      [ -z "$_ifname" ] && continue
      _i=$((_i+1))
      _iface_names+=("$_ifname")
      printf '    %d) %-16s  %s  (%s)\n' "$_i" "$_ifname" "$_imac" "$_istate" >&2
    done < <(
      command -v ip >/dev/null 2>&1 \
        && ip -br link show 2>/dev/null \
            | awk '$1!="lo" && $1!~/^(docker|veth|br-|cni|flannel|kube-bridge|kube-ipvs|tailscale|wg)/ {
                     printf "%s\t%s\t%s\n", $1, $3, $2
                   }'
    )
    if [ "${#_iface_names[@]}" -eq 0 ]; then
      printf '  (no other interfaces detected; keeping "%s" — phase 9 will set it up later)\n' "$nic_iface" >&2
    else
      printf '\n  Pick a number [1-%d] to use that interface, or press Enter to keep "%s".\n' \
        "${#_iface_names[@]}" "$nic_iface" >&2
      printf '  Pressing Enter only makes sense if you have phase 9 selectors set\n' >&2
      printf '  (mac/pci/driver) so phase 9 can rename a real NIC to "%s".\n' "$nic_iface" >&2
      local _pick
      printf '  > ' >&2
      IFS= read -r _pick </dev/tty || return 1
      if [ -n "$_pick" ] \
         && printf '%s' "$_pick" | grep -Eq '^[0-9]+$' \
         && [ "$_pick" -ge 1 ] && [ "$_pick" -le "${#_iface_names[@]}" ]; then
        nic_iface="${_iface_names[$((_pick-1))]}"
        printf '  ✓ using nic.iface=%s\n' "$nic_iface" >&2
      else
        printf '  keeping nic.iface=%s\n' "$nic_iface" >&2
      fi
    fi
  fi

  # Compute partition's expanded cpu list and pick two distinct
  # defaults: first cpu for IRQs, second (or last) for the SOEM loop.
  # For minimum jitter the IRQ core and the loop core SHOULD differ —
  # async NIC interrupts can preempt the cyclic loop at the wrong
  # microsecond when they share a core.
  local part_cpus_expanded first_cpu second_cpu
  part_cpus_expanded="$(_cpu_isolation_expand_cpus "$partition_cpus")"
  first_cpu="$(printf '%s\n' "$part_cpus_expanded" | head -n1)"
  second_cpu="$(printf '%s\n' "$part_cpus_expanded" | sed -n '2p')"
  [ -z "$second_cpu" ] && second_cpu="$first_cpu"  # 1-cpu partition fallback

  if [ -n "$nic_iface" ]; then
    while :; do
      printf '  NIC IRQ core (integer inside %s) [%s]: ' "$partition_cpus" "$first_cpu" >&2
      IFS= read -r nic_irq </dev/tty || return 1
      [ -z "$nic_irq" ] && nic_irq="$first_cpu"
      case "$nic_irq" in
        ''|*[!0-9]*) printf '    not a number\n' >&2 ;;
        *) break ;;
      esac
    done
  fi

  # SOEM RT loop core. Default to a *different* core from nic_irq.
  local rt_default="$second_cpu"
  if [ -n "$nic_irq" ] && [ "$nic_irq" = "$second_cpu" ]; then
    rt_default="$first_cpu"
  fi
  while :; do
    printf '  SOEM RT loop core (integer inside %s) [%s]: ' "$partition_cpus" "$rt_default" >&2
    IFS= read -r dma_rt_cpu </dev/tty || return 1
    [ -z "$dma_rt_cpu" ] && dma_rt_cpu="$rt_default"
    case "$dma_rt_cpu" in
      ''|*[!0-9]*) printf '    not a number\n' >&2; continue ;;
    esac
    if [ -n "$nic_irq" ] && [ "$dma_rt_cpu" = "$nic_irq" ]; then
      printf '    warning: same core as NIC IRQ (%s) — async interrupts may\n' "$nic_irq" >&2
      printf '    preempt the SOEM loop. Continue anyway? [y/N]: ' >&2
      local same_ans
      IFS= read -r same_ans </dev/tty || return 1
      case "${same_ans,,}" in y|yes) break ;; *) continue ;; esac
    fi
    break
  done

  printf '  install systemd CPUAffinity drop-in? [Y/n]: ' >&2
  IFS= read -r aff_ans </dev/tty || return 1

  local aff_bool="true"
  case "${aff_ans,,}" in n|no) aff_bool="false" ;; esac

  # Build JSON. Validator post-persist re-checks the integers fall
  # inside the partition. Kernel cmdline editing is now always-on
  # under RFC 0004 — no migrateCmdline toggle.
  local nic_field=""
  if [ -n "$nic_iface" ]; then
    nic_field=", \"nic\": {\"iface\": \"$nic_iface\", \"irqCore\": $nic_irq}"
  fi
  local json
  json=$(printf '{"enabled": true, "partitions": [{"name": "%s", "cpus": "%s"}]%s, "dmaRtCpu": %s, "installAffinityDefaults": %s}' \
    "$partition_name" "$partition_cpus" "$nic_field" "$dma_rt_cpu" "$aff_bool")

  if ! _cpu_isolation_persist "$hc" "$json"; then
    return 1
  fi
  pass "persisted cpuIsolation block to $hc"
}

# Expand a kernel cpu-list ("11-13", "10,12-13") to one CPU per line.
_cpu_isolation_expand_cpus() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys
spec = sys.argv[1]
out = []
for part in spec.split(","):
    if "-" in part:
        lo, hi = part.split("-", 1)
        out.extend(range(int(lo), int(hi) + 1))
    else:
        out.append(int(part))
for c in out:
    print(c)
PY
}

# Persist a JSON cpuIsolation blob, then validate the resulting file.
# Reverts the file on validation failure (writes through a tmp copy).
# Prompt the operator for cpuIsolation.dmaRtCpu only — used when an
# existing host-config has nic.irqCore (or legacy nic.rtCore) but no
# top-level dmaRtCpu (i.e. it was persisted by an old prompt before
# the irqCore/dmaRtCpu split landed). Reads the existing JSON, splices
# in dmaRtCpu, persists the merged block, returns 0. Aborts via
# return 1 on EOF / non-numeric input / out-of-partition / explicit
# operator opt-out.
#
# Args:
#   $1  host-config path
#   $2  current cpuIsolation JSON blob
#   $3  current nic.irqCore (so we can default the loop core to a
#        distinct cpu and warn on collision)
_cpu_isolation_prompt_dma_rt_cpu() {
  local hc="$1" ci_json="$2" nic_irq="$3"
  local part_cpus first_cpu second_cpu rt_default rt_input

  # Pull the first declared partition's cpus and pick a default rt
  # loop core that differs from nic_irq.
  part_cpus="$(python3 - "$ci_json" <<'PY' 2>/dev/null
import json, sys
d = json.loads(sys.argv[1] or "{}")
parts = d.get("partitions") or []
print(parts[0].get("cpus", "") if parts else "")
PY
)"
  if [ -z "$part_cpus" ]; then
    fail "no partitions declared — cannot suggest a default dmaRtCpu"
    return 1
  fi

  local part_expanded
  part_expanded="$(_cpu_isolation_expand_cpus "$part_cpus")"
  first_cpu="$(printf '%s\n' "$part_expanded" | head -n1)"
  second_cpu="$(printf '%s\n' "$part_expanded" | sed -n '2p')"
  [ -z "$second_cpu" ] && second_cpu="$first_cpu"

  rt_default="$second_cpu"
  if [ "$nic_irq" = "$second_cpu" ]; then
    rt_default="$first_cpu"
  fi

  while :; do
    printf '\n  SOEM RT loop core (integer inside %s, distinct from nic.irqCore=%s) [%s]: ' \
      "$part_cpus" "$nic_irq" "$rt_default" >&2
    IFS= read -r rt_input </dev/tty || return 1
    [ -z "$rt_input" ] && rt_input="$rt_default"
    case "$rt_input" in
      ''|*[!0-9]*) printf '    not a number\n' >&2; continue ;;
    esac
    # Must be inside the partition.
    if ! printf '%s\n' "$part_expanded" | grep -qx "$rt_input"; then
      printf '    %s is not inside %s\n' "$rt_input" "$part_cpus" >&2
      continue
    fi
    if [ "$rt_input" = "$nic_irq" ]; then
      printf '    warning: same core as NIC IRQ (%s) — async interrupts may\n' "$nic_irq" >&2
      printf '    preempt the SOEM loop. Continue with co-located cores? [y/N]: ' >&2
      local same_ans
      IFS= read -r same_ans </dev/tty || return 1
      case "${same_ans,,}" in y|yes) break ;; *) continue ;; esac
    fi
    break
  done

  # Splice dmaRtCpu into the existing JSON; also rename the legacy
  # nic.rtCore field to nic.irqCore so the next run has no
  # deprecation warning. Persist the merged block.
  local merged
  merged="$(python3 - "$ci_json" "$rt_input" <<'PY'
import json, sys
d = json.loads(sys.argv[1] or "{}")
d["dmaRtCpu"] = int(sys.argv[2])
nic = d.get("nic") or {}
if isinstance(nic, dict) and "rtCore" in nic and "irqCore" not in nic:
    nic["irqCore"] = nic.pop("rtCore")
    d["nic"] = nic
print(json.dumps(d))
PY
)"
  if ! _cpu_isolation_persist "$hc" "$merged"; then
    return 1
  fi
  pass "persisted cpuIsolation.dmaRtCpu=$rt_input to $hc"
}

_cpu_isolation_persist() {
  local hc="$1" json="$2"
  local backup
  backup="$(mktemp)"
  cp "$hc" "$backup" || return 1
  if ! python3 "$HOST_CONFIG_HELPER" "$hc" set-cpu-isolation-json "$json" >/dev/null 2>&1; then
    cp "$backup" "$hc"; rm -f "$backup"
    fail "could not write cpuIsolation block to $hc"
    return 1
  fi
  if ! python3 "$HOST_CONFIG_HELPER" "$hc" validate >/dev/null 2>&1; then
    cp "$backup" "$hc"; rm -f "$backup"
    fail "cpuIsolation block did not validate — restored $hc"
    info "validator output:"
    python3 "$HOST_CONFIG_HELPER" "$hc" validate >&2 || true
    return 1
  fi
  rm -f "$backup"
}

configure_dma_ethercat_env() {
  local hc="$1"
  local robot="${ROBOT:-}"
  if [ -z "$robot" ]; then
    ethercat_die "robot id not resolved — cannot pick dma-ethercat config"
  fi

  # Resolution order:
  #   1. host-config dmaEthercat.configPath (absolute, or relative to
  #      DMA_ETHERCAT_CONFIG_DIR)
  #   2. host-config dmaEthercat.configSet -> <set>/<robot>.json
  #   3. auto-detect: <robot>.json or <robot>/<robot>.json
  #   4. interactive prompt (TTY only); persist selection back to
  #      host-config as configPath
  #   5. die with the available files listed
  local config_path="" config_set="" candidate=""
  if [ -r "$hc" ]; then
    config_path="$(python3 "$REPO_ROOT/scripts/lib/host-config.py" \
                    "$hc" get-dma-ethercat-config-path 2>/dev/null || true)"
    config_set="$(python3 "$REPO_ROOT/scripts/lib/host-config.py" \
                    "$hc" get-dma-ethercat-config-set 2>/dev/null || true)"
  fi

  if [ -n "$config_path" ]; then
    case "$config_path" in
      /*) candidate="$config_path" ;;
      *)  candidate="$DMA_ETHERCAT_CONFIG_DIR/$config_path" ;;
    esac
    note "host-config dmaEthercat.configPath=$config_path"
    if [ ! -r "$candidate" ]; then
      fail "no config at $candidate"
      ethercat_die "dmaEthercat.configPath=$config_path, but $candidate is missing — check the .deb ships this file or update configPath"
    fi
  elif [ -n "$config_set" ]; then
    candidate="$DMA_ETHERCAT_CONFIG_DIR/$config_set/$robot.json"
    note "host-config dmaEthercat.configSet=$config_set"
    if [ ! -r "$candidate" ]; then
      fail "no config at $candidate"
      ethercat_die "dmaEthercat.configSet=$config_set, but $candidate is missing — set dmaEthercat.configPath to a specific JSON instead"
    fi
  else
    local c1="$DMA_ETHERCAT_CONFIG_DIR/$robot.json"
    local c2="$DMA_ETHERCAT_CONFIG_DIR/$robot/$robot.json"
    if   [ -r "$c1" ]; then candidate="$c1"
    elif [ -r "$c2" ]; then candidate="$c2"
    else
      # Interactive fallback. Only prompt when stdin is a TTY; in CI
      # or non-interactive runs we keep the old hard-fail behaviour.
      if [ -t 0 ] && [ "$DRY_RUN" != 1 ]; then
        candidate="$(_dma_ethercat_prompt_for_config "$robot")" || \
          ethercat_die "no JSON selected — rerun and pick a config, or set dmaEthercat.configPath in $hc"

        # Persist as configPath (relative form when under config dir).
        local persist="$candidate"
        case "$candidate" in
          "$DMA_ETHERCAT_CONFIG_DIR"/*)
            persist="${candidate#"$DMA_ETHERCAT_CONFIG_DIR"/}"
            ;;
        esac
        if [ -r "$hc" ]; then
          if python3 "$REPO_ROOT/scripts/lib/host-config.py" \
              "$hc" set-dma-ethercat-config-path "$persist" >/dev/null 2>&1; then
            pass "persisted dmaEthercat.configPath=$persist to $hc"
          else
            info "could not persist configPath to $hc — next bootstrap will re-prompt"
          fi
        else
          info "$hc not writable — next bootstrap will re-prompt"
        fi
      else
        fail "no dma-ethercat config for robot '$robot'"
        info "searched:"
        info "  $c1"
        info "  $c2"
        info "available entries under $DMA_ETHERCAT_CONFIG_DIR:"
        ls -1 "$DMA_ETHERCAT_CONFIG_DIR" 2>&1 | sed 's/^/    /' || true
        ethercat_die "set dmaEthercat.configPath in $hc (e.g. test_single_novanta/phantom-0001.json), or rerun on a TTY to be prompted"
      fi
    fi
  fi
  pass "resolved DMA_CONFIG: $candidate"

  # Resolve cpuset values from host-config cpuIsolation (read by phase
  # 7). The .deb's dma-ethercat.service unit reads INTERFACE,
  # DMA_CPU_AFFINITY, and DMA_RT_CPU from /etc/dma/dma-ethercat.env;
  # phase 12 here is the place to land them so the unit's first start
  # has the right pinning. Empty when cpuIsolation is absent — those
  # keys are simply not written (existing values in the conffile are
  # preserved if they predate this run).
  local ci_json="" iface="" rt_cpu="" cpu_affinity="" nic_irq=""
  if [ -r "$hc" ]; then
    ci_json="$(python3 "$REPO_ROOT/scripts/lib/host-config.py" \
                 "$hc" get-cpu-isolation-json 2>/dev/null || echo '{}')"
  fi
  if [ -n "$ci_json" ] && [ "$ci_json" != "{}" ]; then
    cpu_affinity="$(_resolve_dma_cpu_affinity "$ci_json")"
    { read -r iface; read -r nic_irq; } < <(cpusets_json_nic "$ci_json")
    # DMA_RT_CPU comes from cpuIsolation.dmaRtCpu (the SOEM loop core).
    # Legacy configs without dmaRtCpu fall back to nic.irqCore so they
    # still produce a usable env file (matches old same-core behaviour).
    # Phase 8 should have already converted such configs by prompting
    # the operator for dmaRtCpu — if we still hit this path (e.g.
    # phase 10 was --skipped), surface a visible warning so it's never
    # silent.
    rt_cpu="$(cpusets_json_dma_rt_cpu "$ci_json")"
    if [ -z "$rt_cpu" ]; then
      rt_cpu="$nic_irq"
      if [ -n "$nic_irq" ]; then
        info "WARN  cpuIsolation.dmaRtCpu unset; co-locating SOEM loop on nic.irqCore=$nic_irq"
        info "WARN  add 'dmaRtCpu: <distinct cpu>' under cpuIsolation for low-jitter EtherCAT"
      fi
    elif [ -n "$nic_irq" ] && [ "$rt_cpu" = "$nic_irq" ]; then
      info "WARN  cpuIsolation.dmaRtCpu=$rt_cpu equals nic.irqCore — async NIC IRQs"
      info "WARN  may preempt the SOEM loop. Pick distinct cores for hard-RT."
    fi
  fi

  # Write DMA_CONFIG (and optionally INTERFACE, DMA_CPU_AFFINITY,
  # DMA_RT_CPU) into the env file in place. Preserve every other line —
  # the file is a dpkg conffile, so unrelated comments and operator
  # tweaks must survive.
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  set DMA_CONFIG=$candidate in $DMA_ETHERCAT_ENV_FILE"
    [ -n "$iface" ]        && info "DRY-RUN  set INTERFACE=$iface"
    [ -n "$cpu_affinity" ] && info "DRY-RUN  set DMA_CPU_AFFINITY=$cpu_affinity"
    [ -n "$rt_cpu" ]       && info "DRY-RUN  set DMA_RT_CPU=$rt_cpu"
    return
  fi

  mkdir -p "$(dirname "$DMA_ETHERCAT_ENV_FILE")"
  local tmp
  tmp="$(mktemp)"
  if [ -r "$DMA_ETHERCAT_ENV_FILE" ]; then
    # Strip every key we're about to rewrite. Preserves comments,
    # other variables, and blank lines.
    grep -vE '^[[:space:]]*(DMA_CONFIG|INTERFACE|DMA_CPU_AFFINITY|DMA_RT_CPU)=' \
      "$DMA_ETHERCAT_ENV_FILE" > "$tmp" || true
  fi
  printf 'DMA_CONFIG=%s\n' "$candidate" >> "$tmp"
  [ -n "$iface" ]        && printf 'INTERFACE=%s\n' "$iface" >> "$tmp"
  [ -n "$cpu_affinity" ] && printf 'DMA_CPU_AFFINITY=%s\n' "$cpu_affinity" >> "$tmp"
  [ -n "$rt_cpu" ]       && printf 'DMA_RT_CPU=%s\n' "$rt_cpu" >> "$tmp"
  if ! mv "$tmp" "$DMA_ETHERCAT_ENV_FILE"; then
    rm -f "$tmp"
    fail "could not write $DMA_ETHERCAT_ENV_FILE"
    ethercat_die "could not update $DMA_ETHERCAT_ENV_FILE — check permissions"
  fi
  chmod 0644 "$DMA_ETHERCAT_ENV_FILE"
  if [ -n "$iface" ] || [ -n "$cpu_affinity" ] || [ -n "$rt_cpu" ]; then
    pass "wrote DMA_CONFIG, cpuset (INTERFACE=$iface DMA_CPU_AFFINITY=$cpu_affinity DMA_RT_CPU=$rt_cpu) to $DMA_ETHERCAT_ENV_FILE"
  else
    pass "wrote DMA_CONFIG to $DMA_ETHERCAT_ENV_FILE"
  fi
}

# Pick the partition cpus that should populate DMA_CPU_AFFINITY. When
# nic.rtCore is set, prefer the partition that contains it (so the RT
# loop and its affinity superset stay coherent). Otherwise fall back
# to the first declared partition. Echoes the cpus string ("10-13",
# "11,12,13", etc.) or empty when cpuIsolation has no partitions.
_resolve_dma_cpu_affinity() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys

def expand(spec):
    out = set()
    for part in spec.split(","):
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.update(range(int(lo), int(hi) + 1))
        else:
            out.add(int(part))
    return out

data = json.loads(sys.argv[1] or "{}")
parts = data.get("partitions") or []
if not parts:
    sys.exit(0)

rt = (data.get("nic") or {}).get("rtCore")
chosen = None
if isinstance(rt, int):
    for p in parts:
        try:
            if rt in expand(p.get("cpus", "")):
                chosen = p
                break
        except (ValueError, AttributeError):
            continue
if chosen is None:
    chosen = parts[0]
print(chosen.get("cpus", ""))
PY
}

# ---- phase 13: gitops ----------------------------------------------------

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
LOCAL_GIT_TREE="${LOCAL_GIT_TREE:-/opt/Phantom-OS-KubernetesOptions}"

# Resolve the (repoURL, targetRevision) pair the per-stack Applications
# should point at. host-config's gitSource: field decides which mode:
#
#   gitSource: local  (RFC 0006 default) — repoURL=file:///opt/.../,
#     targetRevision pinned to the SHA of HEAD inside that working tree
#     so each `dpkg -i` of a new .deb yields a stable, reproducible
#     revision string in `kubectl get application -o yaml`. Pinning
#     beats `HEAD` because HEAD moves on every install; the SHA freezes
#     Argo to exactly the .deb's snapshot.
#
#   gitSource: remote — repoURL stays at $DEFAULT_REPO_URL (GitHub),
#     targetRevision comes from host-config's targetRevision: field
#     (default 'main'). This is the pre-RFC-0006 behavior, retained for
#     fleet ops who push hot-fixes via GitHub or CI test machines that
#     run against a feature branch.
#
# Echoes "<repo_url>\t<target_revision>" on stdout. If gitSource=local
# but the local tree isn't a git repo (older .deb without Phase 1 of
# RFC 0006), falls back to remote and prints a warning so operators
# notice. An unknown gitSource value is a hard error — host-config.py
# is supposed to validate; if it didn't, fail loud rather than guess.
_resolve_git_source() {
  local hc="$1"
  local git_source repo_url target_rev
  if [ -r "$hc" ]; then
    git_source="$(python3 "$HOST_CONFIG_HELPER" "$hc" get-git-source 2>/dev/null \
                  || printf 'local')"
  else
    git_source="local"
  fi
  case "$git_source" in
    local)
      repo_url="file://${LOCAL_GIT_TREE}"
      if [ -d "${LOCAL_GIT_TREE}/.git" ]; then
        target_rev="$(git -C "${LOCAL_GIT_TREE}" rev-parse HEAD 2>/dev/null \
                       || printf 'main')"
      else
        # Warnings go to stderr — _resolve_git_source's stdout is the
        # captured "<repo>\t<rev>" payload, must not be polluted.
        info "warning: ${LOCAL_GIT_TREE}/.git missing — gitSource=local needs a git-initialized .deb" >&2
        info "warning: falling back to repoURL=$DEFAULT_REPO_URL targetRevision=main" >&2
        repo_url="$DEFAULT_REPO_URL"
        target_rev="main"
      fi
      ;;
    remote)
      repo_url="$DEFAULT_REPO_URL"
      if [ -r "$hc" ]; then
        target_rev="$(python3 "$HOST_CONFIG_HELPER" "$hc" get targetRevision 2>/dev/null \
                       || printf '%s' "$DEFAULT_TARGET_REVISION")"
      else
        target_rev="$DEFAULT_TARGET_REVISION"
      fi
      [ -z "$target_rev" ] && target_rev="$DEFAULT_TARGET_REVISION"
      ;;
    *)
      fail "unknown gitSource=$git_source — expected 'local' or 'remote'" >&2
      return 1
      ;;
  esac
  printf '%s\t%s' "$repo_url" "$target_rev"
}

# Ensure $LOCAL_GIT_TREE (default /opt/Phantom-OS-KubernetesOptions)
# exists on the host so argocd-repo-server's hostPath mount (configured
# unconditionally in terraform/main.tf) starts cleanly.
#
# Two supported invocation modes:
#
#   1. installed     — REPO_ROOT == $LOCAL_GIT_TREE (the .deb laid down
#                      the tree at /opt/...). Nothing to do; skip.
#
#   2. checkout      — REPO_ROOT != $LOCAL_GIT_TREE (the operator is
#                      running the script from a git clone anywhere on
#                      disk). Stage the tree by symlinking
#                      $LOCAL_GIT_TREE -> $REPO_ROOT. kubelet follows
#                      symlinks for hostPath type=Directory, so the
#                      mount succeeds and the rendered Application
#                      (repoURL=file://$LOCAL_GIT_TREE) keeps a stable
#                      path inside the repo-server pod.
#
# Idempotent: a symlink already pointing at REPO_ROOT is a no-op. If a
# real directory exists at $LOCAL_GIT_TREE and REPO_ROOT differs (a
# foreign .deb tree), bootstrap refuses and tells the operator to
# teardown the .deb first — we don't clobber dpkg-managed files.
_stage_source_tree() {
  local target="${LOCAL_GIT_TREE:-/opt/Phantom-OS-KubernetesOptions}"

  if [ "$REPO_ROOT" = "$target" ]; then
    skip "source tree already at $target (installed mode)"
    return 0
  fi

  if [ -L "$target" ]; then
    local cur
    cur="$(readlink -f -- "$target" 2>/dev/null || true)"
    if [ "$cur" = "$REPO_ROOT" ]; then
      skip "source tree symlink already points at $REPO_ROOT"
      return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  re-point $target -> $REPO_ROOT  (was -> ${cur:-?})"
      return 0
    fi
    if rm -f -- "$target" && ln -s -- "$REPO_ROOT" "$target"; then
      pass "re-pointed $target -> $REPO_ROOT  (was -> ${cur:-?})"
      return 0
    fi
    fail "could not re-point $target -> $REPO_ROOT"
    return 1
  fi

  if [ -d "$target" ]; then
    fail "$target exists as a directory (likely a .deb install) and does not match REPO_ROOT=$REPO_ROOT"
    info "either run the bootstrap from $target/scripts/, or remove the .deb (teardown.sh / apt remove) first"
    return 1
  fi

  if [ -e "$target" ]; then
    fail "$target exists and is neither a symlink nor a directory"
    return 1
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  mkdir -p $(dirname "$target") && ln -s $REPO_ROOT $target"
    return 0
  fi
  mkdir -p -- "$(dirname "$target")" || { fail "mkdir $(dirname "$target")"; return 1; }
  if ln -s -- "$REPO_ROOT" "$target"; then
    pass "staged source tree: $target -> $REPO_ROOT"
    return 0
  fi
  fail "could not create symlink $target -> $REPO_ROOT"
  return 1
}

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

  # Inject spec.source.kustomize.{images,patches} from host-config so
  # ArgoCD's first reconcile renders the right tags + per-host mounts
  # in one shot. Phases 10/11 still re-run this same path for day-2
  # changes (edited host-config), but full bootstrap doesn't need them
  # in the critical path.
  local hc="$HOST_CONFIG_FILE"
  if [ ! -r "$hc" ]; then
    return 0
  fi
  local inject_out
  if ! inject_out="$(python3 "$HOST_CONFIG_HELPER" "$hc" \
        inject-kustomize-block "$out" "$stack" \
        "$REPO_ROOT/manifests/stacks" 2>&1)"; then
    fail "inject-kustomize-block failed: $inject_out"
    return 1
  fi
  info "$inject_out"
}

gitops() {
  if [ "$SKIP_GITOPS" = 1 ]; then phase "phase 13: gitops  (skipped)"; return; fi
  phase "phase 13: gitops (install argocd + apply per-host Application)"

  # argocd-repo-server mounts $LOCAL_GIT_TREE (/opt/Phantom-OS-KubernetesOptions)
  # as a hostPath volume (terraform/main.tf). Stage that path here — for
  # .deb installs it already exists (skip); for checkout-mode runs we
  # symlink it to REPO_ROOT so kubelet's type=Directory check passes and
  # the rendered Application's file:///opt/... repoURL resolves inside
  # the repo-server pod.
  _stage_source_tree || return

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

  # Resolve (repoURL, targetRevision) once for this gitops run via
  # _resolve_git_source — driven by host-config's gitSource: field
  # (RFC 0006). The same pair is reused across every enabled stack.
  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi
  local git_pair repo_url target_rev
  if ! git_pair="$(_resolve_git_source "$hc")"; then
    return
  fi
  repo_url="$(printf '%s' "$git_pair" | cut -f1)"
  target_rev="$(printf '%s' "$git_pair" | cut -f2)"
  if [ -z "$repo_url" ] || [ -z "$target_rev" ]; then
    fail "could not resolve repoURL/targetRevision from host-config (gitSource)"
    return
  fi
  info "gitops source: repoURL=$repo_url  targetRevision=$target_rev"

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
      info "DRY-RUN    render template for stack=$stack  repoURL=$repo_url  targetRevision=$target_rev  selfHeal=$sh"
      info "DRY-RUN    kubectl apply -f $(_rendered_app_path "$stack")"
      info "DRY-RUN    kubectl -n argocd annotate application/phantomos-$ROBOT-$stack argocd.argoproj.io/refresh=hard --overwrite"
    done <<< "$enabled_stacks"
    info "DRY-RUN  wait for each phantomos-$ROBOT-<stack> Synced + Healthy"
    return
  fi

  # If ArgoCD is already installed (not via this terraform state), import
  # the existing resources so `terraform apply` doesn't try to create
  # them and trip on AlreadyExists / "name still in use". Common after a
  # partial earlier bootstrap whose state file was lost / never
  # persisted. Detect both the namespace and the Helm release; the
  # release is detected via its helm-managed Secret (set by the helm
  # provider when the chart is installed).
  local argocd_ns_exists=0 argocd_release_exists=0
  if "${KUBECTL[@]}" get ns argocd >/dev/null 2>&1; then
    argocd_ns_exists=1
    if "${KUBECTL[@]}" -n argocd get secret \
         -l owner=helm,name=argocd \
         -o name 2>/dev/null | grep -q 'sh.helm.release'; then
      argocd_release_exists=1
    fi
  fi

  (
    cd "$REPO_ROOT/terraform" || exit 2
    terraform init -input=false -upgrade=false
  ) || { fail "terraform init"; return; }

  # Imports are idempotent: if a resource is already in state,
  # `terraform import` exits non-zero with "Resource already managed in
  # state". We treat both that and "Import successful" as success.
  _tf_import() {
    local addr="$1" id="$2" label="$3"
    if (
      cd "$REPO_ROOT/terraform" || exit 2
      terraform import -input=false -var="kubeconfig=$kc" \
        "$addr" "$id" 2>&1 \
        | grep -qE 'already managed|Import successful'
    ); then
      info "$label adopted into terraform state"
    fi
  }
  if [ "$argocd_ns_exists" = 1 ]; then
    _tf_import kubernetes_namespace.argocd argocd "argocd namespace"
  fi
  if [ "$argocd_release_exists" = 1 ]; then
    _tf_import helm_release.argocd argocd/argocd "argocd helm release"
  fi
  unset -f _tf_import
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
    if ! _gitops_render_app "$stack" "$repo_url" "$target_rev" "$sh"; then
      return
    fi
    pass "rendered $(_rendered_app_path "$stack")  stack=$stack  revision=$target_rev  selfHeal=$sh"

    if ! "${KUBECTL[@]}" apply -f "$(_rendered_app_path "$stack")" >/dev/null; then
      fail "kubectl apply -f $(_rendered_app_path "$stack")"
      return
    fi
    pass "phantomos-$ROBOT-$stack applied"
  done <<< "$enabled_stacks"

  # Post-render Argo refresh — best-effort. Forces argocd-application-
  # controller to re-clone the repoURL and re-render manifests RIGHT NOW
  # instead of waiting up to 3 minutes for its next poll. Especially
  # important after a `dpkg -i` advances /opt/.../HEAD: without this,
  # operators see "I just installed a new .deb but the cluster is still
  # on the old manifests" for several minutes. Failures here are not
  # fatal — Argo will eventually re-evaluate on its own.
  while IFS= read -r stack; do
    [ -z "$stack" ] && continue
    local app="phantomos-${ROBOT}-${stack}"
    if "${KUBECTL[@]}" -n argocd get application "$app" >/dev/null 2>&1; then
      "${KUBECTL[@]}" -n argocd annotate "application/$app" \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
      info "triggered hard refresh on $app"
    fi
  done <<< "$enabled_stacks"

  # No Synced wait — phases 10 (image-overrides) and 11 (deployments)
  # only need the Application resource to exist (kubectl apply above
  # makes it so), not for ArgoCD to have reconciled yet. Their patches
  # land on the spec; ArgoCD's next reconcile renders with them in
  # place. The validate phase confirms Healthy.
}

# ---- phase 14b: load-image-tars (optional, between gitops + overrides) -
#
# Load + push prebuilt phantom-models / phantom-policies image tarballs
# into the in-cluster localhost:5443 registry, then wire the loaded tag
# into host-config.yaml's images: block. The registry op itself lives in
# scripts/load-image-tars.sh (pure, off-robot-usable); this phase adds
# the registry-readiness wait, the host-config edit, and the interactive
# prompt. It runs BEFORE image_overrides so the unchanged image_overrides
# phase injects the new tag into the live Application — no duplicated
# injection logic here.
#
# Trigger: act only on --phantom-models-tar / --phantom-policies-tar in a
# non-interactive run (-y, selected-phases mode, or no TTY). On an
# interactive full bootstrap, prompt for any path not pre-filled by a
# flag. If neither resolves to a path, this is a no-op.
load_image_tars() {
  if [ "$SKIP_LOAD_IMAGE_TARS" = 1 ]; then phase "phase 14b: load-image-tars  (skipped)"; return; fi
  phase "phase 14b: load-image-tars (load + push prebuilt model/policy tarballs)"

  # Resolve the two tar paths. Flags win; on an interactive TTY (not -y,
  # stdin is a terminal) prompt for any path a flag did not provide.
  local models_tar="$PHANTOM_MODELS_TAR"
  local policies_tar="$PHANTOM_POLICIES_TAR"
  if [ "$YES" = 0 ] && [ -t 0 ]; then
    local reply
    if [ -z "$models_tar" ]; then
      printf 'phantom-models tarball path? [Enter to skip] '
      read -r reply || true
      models_tar="$reply"
    fi
    if [ -z "$policies_tar" ]; then
      printf 'phantom-policies tarball path? [Enter to skip] '
      read -r reply || true
      policies_tar="$reply"
    fi
  fi

  # Optional no-op: nothing to load.
  if [ -z "$models_tar" ] && [ -z "$policies_tar" ]; then
    info "no tarballs provided — skipping"
    return
  fi

  # Wait for the in-cluster registry Deployment to become Available before
  # pushing. Soft: kubectl absent or the Deployment never coming up is a
  # skip-with-guidance, NOT a bootstrap failure (mirrors
  # validate-local-registry.sh's wait_for_registry).
  local reg_ns="registry" reg_deploy="k0s-registry" reg_wait="120"
  if [ "${#KUBECTL[@]}" -eq 0 ]; then
    skip "kubectl unavailable — cannot confirm registry is up; re-run --load-image-tars once the cluster is reachable"
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  ${KUBECTL[*]} -n $reg_ns wait --for=condition=Available deploy/$reg_deploy --timeout=${reg_wait}s"
  else
    info "waiting up to ${reg_wait}s for deploy/$reg_deploy in $reg_ns to become Available..."
    if ! "${KUBECTL[@]}" -n "$reg_ns" wait \
         --for=condition=Available "deploy/$reg_deploy" \
         "--timeout=${reg_wait}s" >/dev/null 2>&1; then
      skip "deploy/$reg_deploy not Available within ${reg_wait}s — registry down; re-run --load-image-tars once it is up"
      return
    fi
    info "deploy/$reg_deploy Available"
  fi

  local loader="$REPO_ROOT/scripts/load-image-tars.sh"
  if [ ! -f "$loader" ]; then
    fail "scripts/load-image-tars.sh not found"; return
  fi

  local edited=0
  # (container, tarball-path) pairs. The container name doubles as the
  # localhost:5443/<container> repo the loader pushes, so we match the
  # pushed ref by that prefix.
  local pair container path out ref
  for pair in "phantom-models|$models_tar" "phantom-policies|$policies_tar"; do
    container="${pair%%|*}"
    path="${pair#*|}"
    [ -z "$path" ] && continue

    if [ "$DRY_RUN" = 1 ]; then
      info "DRY-RUN  bash $loader $path"
      info "DRY-RUN  python3 $HOST_CONFIG_HELPER $HOST_CONFIG_FILE set-image $container <localhost:5443/$container:TAG-from-tar> (ref unknown in dry-run)"
      continue
    fi

    info "loading + pushing $container from $path"
    # load-image-tars.sh prints `PUSHED localhost:5443/<name>:<tag>` lines
    # to stdout (human logs go to stderr); exit code = failure count.
    if ! out="$(bash "$loader" "$path")"; then
      fail "$container tarball load/push failed"
      continue
    fi
    ref="$(printf '%s\n' "$out" \
            | grep '^PUSHED ' \
            | awk '{print $2}' \
            | grep "^localhost:5443/$container:" \
            | head -1)"
    if [ -z "$ref" ]; then
      fail "$container tarball load/push failed"
      continue
    fi
    if python3 "$HOST_CONFIG_HELPER" "$HOST_CONFIG_FILE" set-image "$container" "$ref"; then
      edited=1
      pass "$container -> $ref (host-config updated)"
    else
      fail "$container pushed as $ref but host-config set-image failed"
    fi
  done

  # In a selected-phase run (--load-image-tars alone, implies -y) the
  # image-overrides phase won't run, so the host-config edit isn't live
  # yet. Tell the operator how to apply it. In a full bootstrap
  # image-overrides runs next and picks it up automatically.
  if [ "$edited" = 1 ] && [ "$SKIP_IMAGE_OVERRIDES" = 1 ]; then
    info "host-config updated; run --image-overrides to apply (automatic in a full bootstrap)"
  fi
}

# ---- phase 15: kustomize image overrides (per-host, per-stack) ---------

# Each entry in host-config's images: list belongs to exactly one stack.
# Bootstrap discovers the mapping by running kustomize on each enabled
# stack and indexing image references in the rendered output. Then it
# patches each stack's Application with only the images it owns.
#
# Every ENABLED stack is patched on every run, including stacks with
# zero routed entries. A stack with no entries gets `kustomize.images:
# []` patched onto its Application, which CLEARS any stale overrides
# left over from a previous bootstrap run. This matters when the
# wizard removes a row from host-config (e.g. operator-ui): without an
# explicit empty-list patch, the prior `:REPLACE-WITH-...` retag would
# persist on the Application and keep the pod in ImagePullBackOff.
#
# The image-to-stack map is computed once and cached for use by both
# image_overrides and dev_mounts (the latter currently only targets
# positronic-control which is hardcoded to `core`, but the same
# mechanism is general-purpose).
_IMAGE_STACK_MAP=""   # newline-separated: "<image>\t<stack>"

_kustomize_cmd() {
  if command -v kustomize >/dev/null 2>&1; then
    printf 'kustomize build\n'
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
    local rendered err
    err="$(mktemp)"
    if ! rendered="$($kk "$REPO_ROOT/manifests/stacks/$stack" 2>"$err")"; then
      fail "kustomize build failed for manifests/stacks/$stack"
      sed 's/^/    /' "$err" >&2
      rm -f "$err"
      return 1
    fi
    rm -f "$err"
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
  if [ "$SKIP_IMAGE_OVERRIDES" = 1 ]; then phase "phase 15: image overrides  (skipped)"; return; fi
  phase "phase 15: image overrides (inject kustomize.images per stack)"

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
  #
  # per_stack is authoritative: every ENABLED stack gets a key, even if
  # host-config has zero entries that route there. Stacks with no
  # entries get an empty list, which the patch loop downstream sends to
  # Argo as `kustomize.images: []`. That empty patch CLEARS any stale
  # overrides left by a prior bootstrap run (e.g. operator-ui retags
  # left over after the wizard removes the row from host-config), so
  # the Application reverts to its manifest defaults.
  local routing_json
  routing_json="$(python3 - "$_IMAGE_STACK_MAP" "$images_json" "$enabled_stacks" <<'PY' 2>&1
import json, sys
mapping_raw, images_json, enabled_stacks_raw = sys.argv[1], sys.argv[2], sys.argv[3]
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
    "foundationbot/dma-ethercat",  # phase 12 install_dma_ethercat
}

# Seed every enabled stack with an empty list. This makes per_stack
# authoritative — stacks with no host-config entries still get a key
# (with []), so the patch loop downstream emits an empty
# `kustomize.images: []` patch and clears any stale overrides from
# prior bootstrap runs.
per_stack: dict[str, list[str]] = {}
for stack in enabled_stacks_raw.splitlines():
    stack = stack.strip()
    if stack:
        per_stack[stack] = []

unrouted: list[str] = []
for entry in json.loads(images_json):
    # entry is "name:newTag" or "name=newName:newTag"
    name = entry.split("=", 1)[0] if "=" in entry else entry.rsplit(":", 1)[0]
    if name in NON_STACK_IMAGES:
        continue
    stack = img_to_stack.get(name)
    if stack and stack in per_stack:
        per_stack[stack].append(entry)
    elif stack:
        # Routing map says this image lives in a stack that isn't
        # enabled on this host — treat as unrouted so the warning
        # below surfaces it.
        unrouted.append(entry)
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
    suffix = " (cleared)" if not imgs else ""
    print(f"  DRY-RUN  patch phantomos-'"$ROBOT"'-{stack} kustomize.images = {imgs}{suffix}")
'
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot patch Application"
    return
  fi

  # Iterate every enabled stack — including those whose kustomize.images
  # list is empty. Patching an empty list is how we clear stale
  # overrides from prior bootstrap runs (see the seed-with-empty-list
  # logic in the heredoc above). Argo treats `images: []` as "no
  # overrides", drops any retag, and the pod rolls onto the manifest
  # default tag.
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
      # Specialize the log line for the empty case so operators can see
      # at a glance that the stack got cleaned (vs. an unhelpful
      # "kustomize.images: []" with no context).
      if [ "$stack_imgs_json" = "[]" ]; then
        pass "patched $app  kustomize.images: [] (cleared)"
      else
        pass "patched $app  kustomize.images: $stack_imgs_json"
      fi
    else
      fail "kubectl patch app $app failed"
      continue
    fi
    "${KUBECTL[@]}" -n argocd patch app "$app" \
      --type=merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 \
      && pass "triggered sync of $app"
  done <<< "$stacks_with_overrides"

  # ---- sub-phase: PHANTOM_CMD persistence -----------------------------
  # (deployments.positronic-control.launchCommand — FIR-407)
  #
  # When host-config.yaml has deployments.positronic-control.launchCommand
  # set, surgically merge a strategic-merge patch on positronic-config
  # (ConfigMap) into the core Application's kustomize.patches. This makes
  # PHANTOM_CMD declarative — Argo re-applies it on every sync, so the
  # live ConfigMap survives `kubectl apply -k` cycles and the next pod
  # roll comes up with the configured launch command (not the manifest's
  # default "" -> sleep infinity). When the field is absent, any prior
  # patch with the same (kind,name,namespace) is REMOVED so behavior
  # reverts to the manifest default.
  #
  # Phase 13 (deployments_phase) emits the same patch in its full
  # kustomize.patches payload — the two phases are consistent. This
  # sub-phase exists so the operator-facing flow `bootstrap-robot.sh
  # --image-overrides` is enough to push PHANTOM_CMD changes without
  # also needing --deployments.
  _patch_positronic_phantom_cmd "$hc"
}

# Surgically merge the positronic-config PHANTOM_CMD ConfigMap patch
# into the core Argo Application's spec.source.kustomize.patches. Read,
# filter out any prior entry targeting ConfigMap/positronic-config, then
# either append a new entry (if
# deployments.positronic-control.launchCommand is set) or leave the rest
# untouched. Designed to be safe to run from phase 15 — does not touch
# image overrides or other patches.
_patch_positronic_phantom_cmd() {
  local hc="$1"
  [ -r "$hc" ] || return 0

  local launch_command
  if ! launch_command="$(python3 - "$hc" <<'PY' 2>/dev/null
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(1)
deployments = cfg.get("deployments") if isinstance(cfg, dict) else None
if not isinstance(deployments, dict):
    sys.exit(2)  # block absent
pc = deployments.get("positronic-control")
if not isinstance(pc, dict):
    sys.exit(2)  # field absent
lc = pc.get("launchCommand")
if lc is None:
    sys.exit(2)  # field absent
# Emit the raw string; downstream JSON-escapes via python.
sys.stdout.write(str(lc))
PY
)"; then
    # Non-zero rc: either yaml parse error (rc=1) or field absent (rc=2).
    # Treat both as "no launchCommand". We still need to scrub any
    # leftover ConfigMap/positronic-config entry from a prior run so
    # removing the field cleanly reverts behavior.
    launch_command=""
    local field_absent=1
  else
    local field_absent=0
  fi

  local app="phantomos-$ROBOT-core"
  if [ ${#KUBECTL[@]} -eq 0 ]; then
    info "no kubectl/k0s available — skipping PHANTOM_CMD sub-phase"
    return
  fi
  if ! "${KUBECTL[@]}" -n argocd get app "$app" >/dev/null 2>&1; then
    info "Application $app not present — skipping PHANTOM_CMD sub-phase"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    if [ "$field_absent" = 1 ]; then
      info "DRY-RUN  scrub any prior ConfigMap/positronic-config patch from $app"
    else
      info "DRY-RUN  set PHANTOM_CMD=$launch_command via $app kustomize.patches"
    fi
    return
  fi

  # Fetch current patches list (may be absent / null / []).
  local current_patches_json
  current_patches_json="$("${KUBECTL[@]}" -n argocd get app "$app" \
      -o jsonpath='{.spec.source.kustomize.patches}' 2>/dev/null || true)"
  [ -z "$current_patches_json" ] && current_patches_json="[]"

  # Compute the new patches list in Python: drop any prior entry whose
  # target is the positronic-config ConfigMap, then (if set) append a
  # fresh entry. Emits a kubectl merge-patch JSON on stdout.
  local merge_patch
  if ! merge_patch="$(LAUNCH_COMMAND="$launch_command" FIELD_ABSENT="$field_absent" \
      CURRENT_PATCHES="$current_patches_json" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    import yaml
except ImportError:
    sys.exit(1)
launch = os.environ["LAUNCH_COMMAND"]
absent = os.environ["FIELD_ABSENT"] == "1"
try:
    current = json.loads(os.environ["CURRENT_PATCHES"]) or []
except json.JSONDecodeError:
    current = []
if not isinstance(current, list):
    current = []

TARGET_KIND = "ConfigMap"
TARGET_NAME = "positronic-config"
TARGET_NS = "positronic"

def is_phantom_cmd_entry(entry: dict) -> bool:
    tgt = entry.get("target") or {}
    return (
        tgt.get("kind") == TARGET_KIND
        and tgt.get("name") == TARGET_NAME
        and tgt.get("namespace") == TARGET_NS
    )

# Drop any prior entry pointing at our ConfigMap target.
filtered = [e for e in current if isinstance(e, dict) and not is_phantom_cmd_entry(e)]

if not absent:
    patch_doc = {
        "apiVersion": "v1",
        "kind": TARGET_KIND,
        "metadata": {"name": TARGET_NAME, "namespace": TARGET_NS},
        "data": {"PHANTOM_CMD": launch},
    }
    filtered.append({
        "target": {
            "kind": TARGET_KIND,
            "name": TARGET_NAME,
            "namespace": TARGET_NS,
        },
        "patch": yaml.safe_dump(patch_doc, sort_keys=False),
    })

print(json.dumps({"spec": {"source": {"kustomize": {"patches": filtered}}}}))
PY
)"; then
    fail "failed to compute kustomize.patches merge (PyYAML missing?)"
    return
  fi

  if "${KUBECTL[@]}" -n argocd patch app "$app" --type=merge -p "$merge_patch" >/dev/null; then
    if [ "$field_absent" = 1 ]; then
      pass "$app  PHANTOM_CMD entry scrubbed (deployments.positronic-control.launchCommand unset)"
    else
      pass "$app  PHANTOM_CMD set declaratively (deployments.positronic-control.launchCommand)"
    fi
  else
    fail "kubectl patch app $app PHANTOM_CMD failed"
    return
  fi

  "${KUBECTL[@]}" -n argocd patch app "$app" \
    --type=merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 \
    && pass "triggered sync of $app"

  # FIR-407 follow-up: roll the positronic-control DaemonSet if the live
  # ConfigMap's PHANTOM_CMD doesn't match the value we just declared. K8s
  # doesn't restart pods on ConfigMap data changes (env-from is read once
  # at container start), so without this the running pod keeps its stale
  # PHANTOM_CMD until something else kills it. We poll the live CM for up
  # to a few seconds to let Argo sync land, then compare and rollout-
  # restart only on actual change. No-op re-runs (same desired value)
  # skip the restart so phase 15 stays idempotent.
  local desired_phantom_cmd="$launch_command"
  if [ "$field_absent" = 1 ]; then desired_phantom_cmd=""; fi
  local current_phantom_cmd=""
  current_phantom_cmd="$("${KUBECTL[@]}" -n positronic get cm positronic-config \
      -o jsonpath='{.data.PHANTOM_CMD}' 2>/dev/null || true)"
  if [ "$desired_phantom_cmd" = "$current_phantom_cmd" ]; then
    return  # no-op — nothing to roll
  fi
  # Argo sync runs async; poll up to ~10s for the ConfigMap to converge
  # to the desired value before rolling. If sync stalls, warn and leave
  # the rollout to a future operator action — don't roll the pod with a
  # stale value.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    current_phantom_cmd="$("${KUBECTL[@]}" -n positronic get cm positronic-config \
        -o jsonpath='{.data.PHANTOM_CMD}' 2>/dev/null || true)"
    [ "$current_phantom_cmd" = "$desired_phantom_cmd" ] && break
  done
  if [ "$current_phantom_cmd" != "$desired_phantom_cmd" ]; then
    warn "PHANTOM_CMD patch applied to Argo but live ConfigMap hasn't converged after 10s; skipping rollout (operator must restart positronic-control manually)"
    return
  fi
  if "${KUBECTL[@]}" -n positronic rollout restart daemonset/positronic-control >/dev/null 2>&1; then
    pass "rolled positronic-control DaemonSet (PHANTOM_CMD change applied)"
  else
    warn "kubectl rollout restart daemonset/positronic-control failed; pod will roll on next pod-kill"
  fi
}

# ---- phase 16: dev hostPath mounts (per-host) --------------------------

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
  if [ "$SKIP_DEV_MOUNTS" = 1 ]; then phase "phase 16: deployments  (skipped)"; return; fi
  phase "phase 16: deployments (inject kustomize.patches per stack)"

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

# ---- phase 14: argocd admin (install CLI + reset password) -------------

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
  if [ "$SKIP_ARGOCD_ADMIN" = 1 ]; then phase "phase 14: argocd admin  (skipped)"; return; fi
  phase "phase 14: argocd admin (install CLI + set admin password)"

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

# ---- phase 17: setup-positronic (optional) --------------------------------

setup_positronic() {
  if [ "$SETUP_POSITRONIC" = 0 ]; then return; fi
  phase "phase 17: setup-positronic"

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

# ---- phase 18: validate --------------------------------------------------

validate() {
  if [ "$SKIP_VALIDATE" = 1 ]; then phase "phase 18: validate  (skipped)"; return; fi
  phase "phase 18: validate"

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

  _step $([ "$SKIP_PURGE_PODS"           = 0 ] && echo 1 || echo 0) "purge workload pods"                    "--skip-purge-pods"
  _step $([ "$SKIP_DOCKER_STOP"          = 0 ] && echo 1 || echo 0) "stop docker containers"                 "--skip-docker-stop"
  _step $([ "$SKIP_STOP_SERVICES"        = 0 ] && echo 1 || echo 0) "stop system services"                   "--skip-stop-services"
  _step $([ "$SKIP_ETHERCAT_UNINSTALL"   = 0 ] && echo 1 || echo 0) "uninstall dma-ethercat"                 "--skip-ethercat-uninstall passed"
  _step 1                                                           "phase  1  preflight"                    ""
  _step 1                                                           "          configure-host (if missing)"  ""
  _step $([ "$SKIP_DEPS"                 = 0 ] && echo 1 || echo 0) "phase  2  deps"                         "--deps not selected"
  _step $([ "$SKIP_CLUSTER"              = 0 ] && echo 1 || echo 0) "phase  3  cluster"                      "--cluster not selected"
  _step $([ "$SKIP_HOST"                 = 0 ] && echo 1 || echo 0) "phase  4  host config"                  "--host not selected"
  _step $([ "$SKIP_SEED_PULL_SECRETS"    = 0 ] && echo 1 || echo 0) "phase  5  seed pull secrets"            "--seed-pull-secrets not selected"
  _step $([ "$SKIP_OPERATOR_UI_CONFIG"   = 0 ] && echo 1 || echo 0) "phase  6  operator-ui-config"           "--operator-ui-config not selected"
  _step $([ "$SKIP_LOCOMOTION_CONFIG"    = 0 ] && echo 1 || echo 0) "phase  7  locomotion-config"               "--locomotion-config not selected"
  _step $([ "$SKIP_SONIC_CONFIG"         = 0 ] && echo 1 || echo 0) "phase  8  sonic-config"                    "--sonic-config not selected"
  _step $([ "$SKIP_PSI_CONFIG"           = 0 ] && echo 1 || echo 0) "phase  8b psi-config"                      "--psi-config not selected"
  _step $([ "$SKIP_ECAT_INTERFACE"       = 0 ] && echo 1 || echo 0) "phase  9  ecat-interface (gates 10)"       "--skip-ecat-interface"
  _step $([ "$SKIP_CPU_ISOLATION"        = 0 ] && echo 1 || echo 0) "phase 10  cpu-isolation (gates 12)"        "--skip-cpu-isolation"
  _step $([ "$SKIP_LOG_MANAGEMENT"       = 0 ] && echo 1 || echo 0) "phase 11  log-management"                  "--skip-log-management"
  _step $([ "$SKIP_INSTALL_DMA_ETHERCAT" = 0 ] && echo 1 || echo 0) "phase 12  install dma-ethercat (gates 13)"  "--skip-ethercat-install passed"
  _step $([ "$SKIP_GITOPS"               = 0 ] && echo 1 || echo 0) "phase 13  gitops"                          "--gitops not selected"
  _step $([ "$SKIP_ARGOCD_ADMIN"         = 0 ] && echo 1 || echo 0) "phase 14  argocd-admin"                    "--argocd-admin not selected"
  _step $([ "$SKIP_LOAD_IMAGE_TARS"      = 0 ] && echo 1 || echo 0) "phase 14b load-image-tars"                 "--load-image-tars not selected"
  _step $([ "$SKIP_IMAGE_OVERRIDES"      = 0 ] && echo 1 || echo 0) "phase 15  image-overrides"                 "--image-overrides not selected"
  _step $([ "$SKIP_DEV_MOUNTS"           = 0 ] && echo 1 || echo 0) "phase 16  deployments"                     "--deployments not selected"
  _step "$SETUP_POSITRONIC"                                         "phase 17  setup-positronic"             "--setup-positronic not set"
  _step $([ "$SKIP_VALIDATE"             = 0 ] && echo 1 || echo 0) "phase 18  validate"                        "--validate not selected"
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

purge_workload_pods     ; guard
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
locomotion_config  ; guard
sonic_config       ; guard
psi_config         ; guard
ensure_cpu_isolation_block ; guard
ecat_interface     ; guard
cpu_isolation      ; guard
log_management     ; guard
install_dma_ethercat ; guard
gitops             ; guard
argocd_admin       ; guard
load_image_tars    ; guard
image_overrides    ; guard
deployments_phase  ; guard
setup_positronic   ; guard
validate

summary
exit "$FAIL"
