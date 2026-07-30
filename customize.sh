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
CACHE="$PERSIST/cache"
ui_print "- Setting up persistent data directory"
mkdir -p "$CACHE"

ui_print "- Staging bundled blacklist for reset/reference"
mkdir -p "$MODPATH/hosts_data"
cp -f "$MODPATH/hosts" "$MODPATH/hosts_data/default_hosts"

if [ ! -f "$CACHE/default.txt" ]; then
  if [ -f "$PERSIST/blacklist.txt" ]; then
    ui_print "- Upgrading from an older version - keeping your existing edits as the new baseline"
    cp -f "$PERSIST/blacklist.txt" "$CACHE/default.txt"
  else
    ui_print "- First install: seeding default blacklist"
    cp -f "$MODPATH/hosts" "$CACHE/default.txt"
  fi
fi

[ -f "$PERSIST/sources.txt" ] || : > "$PERSIST/sources.txt"
[ -f "$PERSIST/user_added.txt" ] || : > "$PERSIST/user_added.txt"
[ -f "$PERSIST/user_removed.txt" ] || : > "$PERSIST/user_removed.txt"

if [ ! -f "$PERSIST/state" ]; then
  echo enabled > "$PERSIST/state"
fi

chmod 0755 "$MODPATH/hosts_ctl.sh"
chmod 0755 "$MODPATH/post-fs-data.sh"

# Compile cache + user edits into blacklist.txt, then patch the hosts file
# that gets mounted at boot, built from that compiled result.
ui_print "- Compiling blacklist"
sh "$MODPATH/hosts_ctl.sh" compile 2>/dev/null
if [ ! -f "$PERSIST/blacklist.txt" ]; then
  # Fall back to a plain copy if hosts_ctl.sh couldn't run in this
  # install context, so blacklist.txt is never left missing.
  cp -f "$CACHE/default.txt" "$PERSIST/blacklist.txt"
fi

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
