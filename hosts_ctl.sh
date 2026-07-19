#!/system/bin/sh
#
# Systemless Hosts - control script
# Backend for the WebUI: list/search/add/remove entries and pause/resume
# filtering live, without a reboot.
#
# Persistent user data lives OUTSIDE the module dir so it survives module
# updates/reinstalls (Magisk/KernelSU/APatch replace $MODDIR wholesale on
# update, but never touch /data/adb/<name>).

MODDIR=/data/adb/modules/systemless-hosts
PERSIST=/data/adb/systemless-hosts
BLACKLIST="$PERSIST/blacklist.txt"
STATE="$PERSIST/state"
LIVE_HOSTS=/system/etc/hosts
MOD_HOSTS="$MODDIR/system/etc/hosts"

log() { echo "[hosts_ctl] $*" >> "$PERSIST/hosts_ctl.log"; }

rebuild() {
  st=$(cat "$STATE" 2>/dev/null)
  mkdir -p "$(dirname "$MOD_HOSTS")"
  if [ "$st" = "disabled" ]; then
    { echo "127.0.0.1 localhost"; echo "::1 localhost"; } > "$MOD_HOSTS"
  else
    cp -f "$BLACKLIST" "$MOD_HOSTS"
  fi
  # Mirror straight onto the live mounted path so pause/resume and edits
  # take effect immediately, no reboot required. This is safe specifically
  # because this module already bind-mounts a writable copy over
  # /system/etc/hosts - we're writing to that same mount, not to /system
  # itself. Falls back silently to "applies after reboot" if the live path
  # isn't writable on some overlay setups.
  cp -f "$MOD_HOSTS" "$LIVE_HOSTS" 2>/dev/null
}

case "$1" in
  rebuild)
    rebuild
    echo ok
    ;;
  status)
    cat "$STATE" 2>/dev/null || echo enabled
    ;;
  enable)
    echo enabled > "$STATE"
    rebuild
    echo ok
    ;;
  disable)
    echo disabled > "$STATE"
    rebuild
    echo ok
    ;;
  count)
    grep -c "^[0-9:]" "$BLACKLIST" 2>/dev/null || echo 0
    ;;
  list)
    # usage: list <offset> <limit>
    offset=${2:-0}
    limit=${3:-200}
    grep "^0\.0\.0\.0 \|^127\.0\.0\.1 " "$BLACKLIST" 2>/dev/null | tail -n "+$((offset+1))" | head -n "$limit"
    ;;
  search)
    # usage: search <term> <limit>
    term="$2"
    limit=${3:-200}
    [ -z "$term" ] && exit 0
    grep -i -- "$term" "$BLACKLIST" 2>/dev/null | grep "^0\.0\.0\.0 \|^127\.0\.0\.1 " | head -n "$limit"
    ;;
  add)
    # usage: add <domain>
    domain="$2"
    [ -z "$domain" ] && { echo "error: no domain"; exit 1; }
    if grep -qxF "127.0.0.1 $domain" "$BLACKLIST" 2>/dev/null; then
      echo "exists"
    else
      echo "127.0.0.1 $domain" >> "$BLACKLIST"
      rebuild
      echo ok
    fi
    ;;
  remove)
    # usage: remove <domain>
    domain="$2"
    [ -z "$domain" ] && { echo "error: no domain"; exit 1; }
    esc=$(printf '%s' "$domain" | sed 's/[.[\*^$/]/\\&/g')
    sed -i "/[[:space:]]${esc}$/d" "$BLACKLIST"
    rebuild
    echo ok
    ;;
  reset)
    cp -f "$MODDIR/hosts_data/default_hosts" "$BLACKLIST"
    rebuild
    echo ok
    ;;
  *)
    echo "usage: $0 {status|enable|disable|count|list|search|add|remove|reset}"
    exit 1
    ;;
esac
