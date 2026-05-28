#!/usr/bin/env bash
# configure-usb-power.sh
#
# Installs a udev rule that disables USB autosuspend for Luxonis OAK
# cameras (idVendor 03e7). Without this, the kernel can power down the
# device between libusb's claim and the firmware-boot rebind, which
# the DepthAI SDK sees as a transient disconnect — the dma-video
# producer pod then crashes on init with "X_LINK_DEVICE_NOT_FOUND".
#
# Harmless on hosts that have no OAK plugged in: the rule only fires
# when a matching device shows up.
#
# One-time per robot. Idempotent — re-running with the rule already in
# place is a no-op (file content compared byte-for-byte).
#
# Usage:
#   sudo bash scripts/configure-usb-power.sh
#

set -eu

RULES_DIR=/etc/udev/rules.d
RULE_FILE="$RULES_DIR/71-oak-usb-power.rules"

read -r -d '' RULE_CONTENT <<'EOF' || true
# Luxonis OAK cameras — disable USB autosuspend so libusb claim and
# the firmware-boot rebind do not race the kernel powering the device
# down. Installed by Phantom-OS-KubernetesOptions bootstrap
# (scripts/configure-usb-power.sh). Re-run that script after editing.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="03e7", \
  ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
EOF

if [ -r "$RULE_FILE" ] && [ "$(cat "$RULE_FILE")" = "$RULE_CONTENT" ]; then
  echo "udev rule already present at $RULE_FILE — no-op"
  exit 0
fi

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
