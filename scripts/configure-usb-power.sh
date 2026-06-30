#!/usr/bin/env bash
# configure-usb-power.sh
#
# Disables USB autosuspend for Luxonis OAK cameras (idVendor 03e7), two
# ways:
#   1. a udev rule (per-device power/control=on) — takes effect after a
#      device enumerates;
#   2. usbcore.autosuspend=-1 on the kernel cmdline (extlinux on Jetson,
#      GRUB on x86) — global, covers the whole enumerate -> bootloader ->
#      firmware-rebind sequence an OAK goes through.
# Without this the kernel can power the device down between libusb's claim
# and the firmware-boot rebind, which the DepthAI SDK sees as a transient
# disconnect — the dma-video producer then crashes with
# "X_LINK_DEVICE_NOT_FOUND" / "No OAK devices found". The udev rule alone
# is not enough; the working fleet (e.g. mk11test) also sets the cmdline
# param, so we do both here.
#
# Harmless on hosts with no OAK plugged in. The cmdline change takes
# effect on the NEXT reboot (this script never auto-reboots).
#
# One-time per robot. Idempotent — re-running is a no-op when the rule is
# already in place and the cmdline param is already set.
#
# Usage:
#   sudo bash scripts/configure-usb-power.sh
#

set -eu

RULES_DIR=/etc/udev/rules.d
RULE_FILE="$RULES_DIR/71-oak-usb-power.rules"
USB3_RULE_FILE="$RULES_DIR/81-oak-usb3.rules"

read -r -d '' RULE_CONTENT <<'EOF' || true
# Luxonis OAK cameras — disable USB autosuspend so libusb claim and
# the firmware-boot rebind do not race the kernel powering the device
# down. Installed by Phantom-OS-KubernetesOptions bootstrap
# (scripts/configure-usb-power.sh). Re-run that script after editing.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="03e7", \
  ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"

# Luxonis OAK access rule (DepthAI's stock 80-movidius.rules): make the
# device world-rw so libusb can claim it without root. The dma-video
# producer runs as root so this is belt-and-suspenders, but it matches
# the upstream DepthAI setup and unblocks any non-root tooling.
SUBSYSTEM=="usb", ATTRS{idVendor}=="03e7", MODE="0666"
EOF

read -r -d '' USB3_RULE_CONTENT <<'EOF' || true
# Keep USB 3.x SuperSpeed controllers/root hubs awake for OAK/Movidius.
# The SuperSpeed controller suspends the instant the OAK bootloader
# disconnects, so the firmware re-enumerates down on USB 2.0 (Bus 1)
# instead of USB 3 — the classic "No OAK devices found" with the device
# stuck on Bus 1. (Sourced from DMA.video/scripts/81-oak-usb3.rules.)
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="03e7", ATTR{speed}=="5000", \
    RUN+="/bin/sh -c 'echo on > /sys$DEVPATH/../power/control'"
ACTION=="add", SUBSYSTEM=="usb", ATTR{speed}=="5000", ATTR{bDeviceClass}=="09", \
    ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{speed}=="10000", ATTR{bDeviceClass}=="09", \
    ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{speed}=="20000", ATTR{bDeviceClass}=="09", \
    ATTR{power/control}="on"
EOF

if [ -r "$RULE_FILE" ] && [ "$(cat "$RULE_FILE")" = "$RULE_CONTENT" ]; then
  echo "udev rule already present at $RULE_FILE — no-op"
else
  mkdir -p "$RULES_DIR"
  if [ -e "$RULE_FILE" ]; then
    cp -p "$RULE_FILE" "$RULE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  printf '%s\n' "$RULE_CONTENT" > "$RULE_FILE"
  chmod 644 "$RULE_FILE"
  echo "wrote $RULE_FILE"

  # Reload rules and apply to any OAK already attached. The trigger is a
  # no-op when no matching device is present, so this is safe on hosts
  # without cameras.
  udevadm control --reload-rules
  udevadm trigger --action=change --subsystem-match=usb --attr-match=idVendor=03e7
  echo "udev rules reloaded; triggered change events for any attached OAK devices"
fi

# Keep the SuperSpeed bus awake so the OAK doesn't re-enumerate down to
# USB 2 between bootloader and firmware. Separate file (matches the
# upstream DMA.video name) so it's obvious what it does.
if [ -r "$USB3_RULE_FILE" ] && [ "$(cat "$USB3_RULE_FILE")" = "$USB3_RULE_CONTENT" ]; then
  echo "udev rule already present at $USB3_RULE_FILE — no-op"
else
  mkdir -p "$RULES_DIR"
  if [ -e "$USB3_RULE_FILE" ]; then
    cp -p "$USB3_RULE_FILE" "$USB3_RULE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  printf '%s\n' "$USB3_RULE_CONTENT" > "$USB3_RULE_FILE"
  chmod 644 "$USB3_RULE_FILE"
  echo "wrote $USB3_RULE_FILE"
  udevadm control --reload-rules
  udevadm trigger --action=add --subsystem-match=usb >/dev/null 2>&1 || true
  echo "SuperSpeed keep-awake rule installed (OAK USB-3 re-enumeration fix)"
fi

# ---------------------------------------------------------------------------
# Also disable USB autosuspend GLOBALLY via the kernel cmdline. The udev rule
# above only takes effect AFTER a device has enumerated, but an OAK needs
# autosuspend off across the whole enumerate -> bootloader -> firmware-rebind
# sequence. The working fleet (e.g. mk11test) sets usbcore.autosuspend=-1 on
# the kernel cmdline; without it the per-device rule alone is not enough and
# the producer can still hit "No OAK devices found". Idempotent; takes effect
# on the NEXT reboot (we never auto-reboot here).
# ---------------------------------------------------------------------------
CMDLINE_PARAM="usbcore.autosuspend=-1"
CMDLINE_RE="usbcore\.autosuspend=-1"

if grep -q "$CMDLINE_RE" /proc/cmdline 2>/dev/null; then
  echo "cmdline: ${CMDLINE_PARAM} already active"
elif [ -f /boot/extlinux/extlinux.conf ]; then          # Jetson / extlinux
  if grep -qE "^[[:space:]]*APPEND.*${CMDLINE_RE}" /boot/extlinux/extlinux.conf; then
    echo "cmdline: ${CMDLINE_PARAM} already in extlinux.conf (reboot pending)"
  else
    cp -p /boot/extlinux/extlinux.conf "/boot/extlinux/extlinux.conf.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i "/^[[:space:]]*APPEND/ s/\$/ ${CMDLINE_PARAM}/" /boot/extlinux/extlinux.conf
    echo "cmdline: added ${CMDLINE_PARAM} to extlinux.conf (backup saved) — REBOOT REQUIRED"
  fi
elif [ -f /etc/default/grub ]; then                      # x86 / GRUB
  if grep -qE "GRUB_CMDLINE_LINUX(_DEFAULT)?=.*${CMDLINE_RE}" /etc/default/grub; then
    echo "cmdline: ${CMDLINE_PARAM} already in /etc/default/grub (reboot pending)"
  else
    cp -p /etc/default/grub "/etc/default/grub.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i "s/\(^GRUB_CMDLINE_LINUX=\"[^\"]*\)\"/\1 ${CMDLINE_PARAM}\"/" /etc/default/grub
    update-grub >/dev/null 2>&1 || grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    echo "cmdline: added ${CMDLINE_PARAM} to /etc/default/grub + regenerated grub — REBOOT REQUIRED"
  fi
else
  echo "cmdline: no extlinux/grub config found — set ${CMDLINE_PARAM} on the kernel cmdline manually"
fi
