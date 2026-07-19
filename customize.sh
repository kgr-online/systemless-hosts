#!/system/bin/sh
#
# Systemless Hosts by the
# open source loving GL-DP and all contributors;
# An efficient ad blocker, now with a WebUI
#

# Check root implementation
ui_print "- Checking root implementation"
if [ "$BOOTMODE" ] && [ "$KSU" ]; then
  ui_print "- Installing from KernelSU app"
  ui_print "   KernelSU version: $KSU_KERNEL_VER_CODE (kernel) + $KSU_VER_CODE (ksud)"
  if [ "$(which magisk)" ]; then
    ui_print "   Multiple root implementation is NOT supported"
    abort    "   Aborting!"
  fi
elif [ "$BOOTMODE" ] && [ "$APATCH" ]; then
  ui_print "- Installing from APatch app"
elif [ "$BOOTMODE" ] && [ "$MAGISK_VER_CODE" ]; then
  ui_print "- Installing from Magisk app"
  ui_print "   Note: Magisk has no built-in WebUI support."
  ui_print "   Use WebUI-X / KsuWebUIStandalone / MMRL to access it."
else
  ui_print "   Installation from recovery is NOT supported"
  ui_print "   Please install from Magisk / KernelSU / APatch app"
  abort    "   Aborting!"
fi

PERSIST=/data/adb/systemless-hosts
ui_print "- Setting up persistent data directory"
mkdir -p "$PERSIST"

ui_print "- Staging bundled blacklist for reset/reference"
mkdir -p "$MODPATH/hosts_data"
cp -f "$MODPATH/hosts" "$MODPATH/hosts_data/default_hosts"

if [ ! -f "$PERSIST/blacklist.txt" ]; then
  ui_print "- First install: seeding working blacklist"
  cp -f "$MODPATH/hosts" "$PERSIST/blacklist.txt"
else
  ui_print "- Existing blacklist found - keeping your edits"
fi

if [ ! -f "$PERSIST/state" ]; then
  echo enabled > "$PERSIST/state"
fi

chmod 0755 "$MODPATH/hosts_ctl.sh"
chmod 0755 "$MODPATH/post-fs-data.sh"

# Patch default hosts file, built from persisted state/blacklist
PATCH_DIR=/system/etc
ui_print "- Patching hosts file"
mkdir -p "$MODPATH$PATCH_DIR"
if [ "$(cat "$PERSIST/state")" = "disabled" ]; then
  { echo "127.0.0.1 localhost"; echo "::1 localhost"; } > "$MODPATH$PATCH_DIR/hosts"
else
  cp -f "$PERSIST/blacklist.txt" "$MODPATH$PATCH_DIR/hosts"
fi

# Clean up
rm -rf "$MODPATH/hosts"
rm -rf "$MODPATH/LICENSE"
