#!/usr/bin/env bash
# teardown.sh — clean up a phantomos-k0s installation in place, so the
# operator can re-run install + bootstrap from a known-clean state.
#
# What --reset does NOT clean (and this script does):
#   /etc/phantomos/                    — wizard output, rendered Application CRs
#   /var/lib/k0s/images/*.tar          — bundled image tarballs
#   /var/lib/k0s/images/.phantomos-*   — bundle manifest sidecar
#   /opt/Phantom-OS-KubernetesOptions  — .deb-installed control plane
#   /etc/default/grub                  — cpu-isolation kernel cmdline edits
#   /etc/systemd/system.conf.d/cpuaffinity.conf  — systemd CPUAffinity drop-in
#
# bootstrap-robot.sh --reset is invoked first (when available) to handle
# k0s, argocd, and terraform state.
#
# Usage:
#   sudo bash scripts/teardown.sh                  # interactive (asks once)
#   sudo bash scripts/teardown.sh --yes            # non-interactive
#   sudo bash scripts/teardown.sh --keep-grub      # don't revert kernel cmdline
#   sudo bash scripts/teardown.sh --dry-run        # show what would happen
#
# After teardown:
#   sudo reboot                                    # clears isolcpus from kernel
# After reboot, re-install:
#   sudo dpkg -i ~/phantomos-k0s-*-all.deb
#   sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh ./
#   sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/configure-host.sh
#   sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh

set -u

YES=0
DRY_RUN=0
KEEP_GRUB=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y)     YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --keep-grub)  KEEP_GRUB=1; shift ;;
    -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)            echo "error: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "error: must run as root (try: sudo bash $0)" >&2
  exit 2
fi

# Pretty-print helpers — match the style of install-image-bundle.sh.
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi
heading() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }
info()    { printf '  %s\n' "$1"; }
pass()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
skip()    { printf '  %s—%s %s\n' "$C_DIM" "$C_RESET" "$1"; }
die()     { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit "${2:-1}"; }

run() {
  # run <cmd...> — execute or echo when dry-run
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %sDRY-RUN%s %s\n' "$C_DIM" "$C_RESET" "$*"
  else
    "$@"
  fi
}

# ---- big-honking-warning gate ----------------------------------------------

heading "Phantom-OS teardown"
info "this WILL:"
info "  - tear down k0s + argocd + terraform state (--reset)"
info "  - remove /etc/phantomos (host-config + rendered Apps)"
info "  - remove /var/lib/k0s/images (bundled tarballs)"
info "  - remove /opt/Phantom-OS-KubernetesOptions (the .deb tree)"
info "  - dpkg -r phantomos-k0s + phantomos-k0s-images"
if [ "$KEEP_GRUB" -eq 0 ]; then
  info "  - revert /etc/default/grub from the most recent .bak"
  info "  - remove /etc/systemd/system.conf.d/cpuaffinity.conf"
fi
echo

if [ "$YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  printf '  proceed? [y/N] '
  IFS= read -r reply
  case "${reply:-n}" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

# ---- 1. bootstrap-robot.sh --reset -----------------------------------------

heading "1. bootstrap-robot.sh --reset --yes"

BR_CANDIDATES=(
  "/opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh"
  "$(dirname "$0")/bootstrap-robot.sh"
)
BR=""
for cand in "${BR_CANDIDATES[@]}"; do
  if [ -x "$cand" ]; then BR="$cand"; break; fi
done

if [ -z "$BR" ]; then
  warn "bootstrap-robot.sh not found — skipping --reset (k0s / argo / terraform"
  warn "state may persist; you may need to uninstall k0s manually)"
else
  run bash "$BR" --reset --yes 2>&1 | tail -10 || \
    warn "bootstrap-robot.sh --reset exited non-zero (continuing)"
fi

# ---- 2. /etc/phantomos -----------------------------------------------------

heading "2. remove /etc/phantomos"
if [ -d /etc/phantomos ]; then
  run rm -rf /etc/phantomos
  pass "removed"
else
  skip "/etc/phantomos already absent"
fi

# ---- 3. /var/lib/k0s/images ------------------------------------------------

heading "3. clean /var/lib/k0s/images"
if [ -d /var/lib/k0s/images ]; then
  n_tar=$(find /var/lib/k0s/images -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)
  if [ "$n_tar" -gt 0 ]; then
    info "removing $n_tar tarball(s) + bundle manifest"
    run find /var/lib/k0s/images -maxdepth 1 -name '*.tar' -delete
    run rm -f /var/lib/k0s/images/.phantomos-image-bundle.yaml
    pass "cleaned"
  else
    skip "no tarballs to remove"
  fi
else
  skip "/var/lib/k0s/images already absent"
fi

# ---- 4. dpkg -r phantomos-k0s* ---------------------------------------------

heading "4. dpkg -r phantomos-k0s-images phantomos-k0s"
for pkg in phantomos-k0s-images phantomos-k0s; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    info "dpkg -r $pkg"
    run dpkg -r "$pkg" >/dev/null 2>&1 || warn "dpkg -r $pkg returned non-zero"
    pass "$pkg removed"
  else
    skip "$pkg not installed"
  fi
done

# ---- 5. /opt/Phantom-OS-KubernetesOptions ---------------------------------

heading "5. force-remove residual /opt/Phantom-OS-KubernetesOptions"
if [ -d /opt/Phantom-OS-KubernetesOptions ]; then
  run rm -rf /opt/Phantom-OS-KubernetesOptions
  pass "removed"
else
  skip "/opt/Phantom-OS-KubernetesOptions already absent"
fi

# ---- 6. grub cmdline (cpu-isolation revert) -------------------------------

if [ "$KEEP_GRUB" -eq 1 ]; then
  heading "6. grub cmdline"
  skip "--keep-grub passed; leaving /etc/default/grub and CPUAffinity in place"
else
  heading "6. revert /etc/default/grub (cpu-isolation edits)"
  backup=$(ls -t /etc/default/grub.bak.* 2>/dev/null | head -1)
  if [ -n "$backup" ]; then
    info "restoring from $backup"
    run cp "$backup" /etc/default/grub
    if [ "$DRY_RUN" -eq 0 ]; then
      run update-grub >/dev/null 2>&1 || warn "update-grub returned non-zero"
    fi
    pass "reverted (reboot needed for the kernel to pick it up)"
  else
    warn "no /etc/default/grub.bak.* found — bootstrap never wrote one, OR"
    warn "the backup was already cleaned up. current isolcpus line:"
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub 2>/dev/null || true
  fi

  # ---- 7. systemd CPUAffinity drop-in ---
  heading "7. revert systemd CPUAffinity drop-in"
  if [ -f /etc/systemd/system.conf.d/cpuaffinity.conf ]; then
    run rm /etc/systemd/system.conf.d/cpuaffinity.conf
    if [ "$DRY_RUN" -eq 0 ]; then
      run systemctl daemon-reexec >/dev/null 2>&1 || true
    fi
    pass "removed"
  else
    skip "/etc/systemd/system.conf.d/cpuaffinity.conf already absent"
  fi
fi

# ---- final state -----------------------------------------------------------

heading "final state"
if [ "$DRY_RUN" -eq 0 ]; then
  info "filesystem:"
  for path in /etc/phantomos /opt/Phantom-OS-KubernetesOptions /var/lib/k0s/images; do
    if [ -e "$path" ]; then
      info "  exists: $path"
    else
      info "  gone:   $path"
    fi
  done
  info "packages:"
  dpkg -l 'phantomos-k0s*' 2>/dev/null | awk '/^ii/ {print "  installed: "$2}' \
    | head -5 || info "  (none installed)"
fi

heading "next steps"
if [ "$KEEP_GRUB" -eq 0 ]; then
  info "1. sudo reboot                                   # clears isolcpus from kernel"
  info "2. cd to wherever the new .debs are, then:"
else
  info "1. cd to wherever the new .debs are, then:"
fi
info "   sudo dpkg -i ./phantomos-k0s-*-all.deb"
info "   sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh ./"
info "   sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/configure-host.sh"
info "   sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh"
echo
