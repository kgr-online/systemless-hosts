#!/system/bin/sh
#
# Systemless Hosts - control script
# Backend for the WebUI: list/search/add/remove entries, import/update
# from remote source lists (like AdAway's list model), and pause/resume
# filtering live, without a reboot.
#
# Persistent user data lives OUTSIDE the module dir so it survives module
# updates/reinstalls (Magisk/KernelSU/APatch replace $MODDIR wholesale on
# update, but never touch /data/adb/<name>).
#
# Data model:
#   cache/default.txt  - the original bundled list (always present)
#   cache/src_N.txt     - one per URL in sources.txt, refreshed by `update`
#   sources.txt         - URLs to fetch, one per line
#   user_added.txt      - domains you added manually (kept forever)
#   user_removed.txt    - domains you removed manually (kept forever -
#                         a source update will never bring these back)
#   blacklist.txt       - compiled result of all of the above; this is
#                         what list/search/count/rebuild actually use
#   state               - enabled/disabled
#   update_status       - running / done:<ts> / error:<msg>

MODDIR=/data/adb/modules/systemless-hosts
PERSIST=/data/adb/systemless-hosts
CACHE="$PERSIST/cache"
SOURCES="$PERSIST/sources.txt"
USER_ADDED="$PERSIST/user_added.txt"
USER_REMOVED="$PERSIST/user_removed.txt"
BLACKLIST="$PERSIST/blacklist.txt"
STATE="$PERSIST/state"
UPDATE_STATUS="$PERSIST/update_status"
LIVE_HOSTS=/system/etc/hosts
MOD_HOSTS="$MODDIR/system/etc/hosts"

ensure_files() {
  mkdir -p "$CACHE"
  [ -f "$SOURCES" ] || : > "$SOURCES"
  [ -f "$USER_ADDED" ] || : > "$USER_ADDED"
  [ -f "$USER_REMOVED" ] || : > "$USER_REMOVED"
}

# Merge cache/*.txt (default list + fetched sources, already normalized to
# "127.0.0.1 domain") with user_added.txt, then drop anything the user
# manually removed - even if a source update re-adds it later.
compile() {
  ensure_files
  tmp="$PERSIST/.compile_tmp"
  merged="$PERSIST/.compile_merged"
  cat "$CACHE"/*.txt "$USER_ADDED" 2>/dev/null \
    | grep -e "^0\.0\.0\.0 " -e "^127\.0\.0\.1 " \
    | awk '{print $2}' \
    | grep -vx -e "localhost" -e "localhost.localdomain" -e "ip6-localhost" -e "ip6-loopback" \
    | sort -u > "$merged"
  if [ -s "$USER_REMOVED" ]; then
    grep -vFxf "$USER_REMOVED" "$merged" > "$tmp"
  else
    cp -f "$merged" "$tmp"
  fi
  sed -i 's/^/127.0.0.1 /' "$tmp"
  mv -f "$tmp" "$BLACKLIST"
  rm -f "$merged"
  rebuild
}

rebuild() {
  st=$(cat "$STATE" 2>/dev/null)
  mkdir -p "$(dirname "$MOD_HOSTS")"
  {
    echo "#"
    echo "# Systemless Hosts by the"
    echo "# open source loving GL-DP and all contributors;"
    echo "# An efficient ad blocker, with a WebUI interface"
    echo "#"
    echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "# Entries: $(wc -l < "$BLACKLIST" 2>/dev/null || echo 0)"
    echo "#"
    echo
    echo "127.0.0.1 localhost"
    echo "::1 localhost"
  } > "$MOD_HOSTS"
  if [ "$st" = "disabled" ]; then
    : # loopback lines above are already enough for a paused/passthrough state
  else
    cat "$BLACKLIST" >> "$MOD_HOSTS"
  fi
  # Mirror straight onto the live mounted path so pause/resume and edits
  # take effect immediately, no reboot required. Safe because this module
  # already bind-mounts a writable copy over /system/etc/hosts - we're
  # writing to that same mount, not to /system itself.
  cp -f "$MOD_HOSTS" "$LIVE_HOSTS" 2>/dev/null
}

fetch() {
  # usage: fetch <url> <output_file>
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 "$url" -o "$out" 2>>"$PERSIST/update.log"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$out" "$url" 2>>"$PERSIST/update.log"
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -q -T 60 -O "$out" "$url" 2>>"$PERSIST/update.log"
  else
    return 2
  fi
}

# Normalize a fetched source (hosts-format OR bare domain list, one per
# line) into "127.0.0.1 domain" lines.
normalize() {
  # usage: normalize <raw_file> <out_file>
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      first=$1
      if (first ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { d=$2 } else { d=first }
      gsub(/\r/, "", d)
      if (d != "" && d !~ /localhost/ && d !~ /^::/) print "127.0.0.1 " d
    }
  ' "$1" > "$2"
}

run_update() {
  ensure_files
  echo "running:$(date +%s)" > "$UPDATE_STATUS"
  : > "$PERSIST/update.log"
  find "$CACHE" -name 'src_*.txt' -delete 2>/dev/null
  i=0
  had_error=0
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    case "$url" in \#*) continue ;; esac
    i=$((i + 1))
    raw="$CACHE/.raw_$i"
    if fetch "$url" "$raw"; then
      if [ -s "$raw" ]; then
        normalize "$raw" "$CACHE/src_$i.txt"
      else
        had_error=1
      fi
    else
      had_error=1
    fi
    rm -f "$raw"
  done < "$SOURCES"
  compile
  if [ "$had_error" = "1" ]; then
    echo "error:one or more sources failed - check update.log:$(date +%s)" > "$UPDATE_STATUS"
  else
    echo "done:$(date +%s)" > "$UPDATE_STATUS"
  fi
}

case "$1" in
  compile)
    compile
    echo ok
    ;;
  rebuild)
    ensure_files
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
    n=$(grep -c "^[0-9:]" "$BLACKLIST" 2>/dev/null)
    [ -z "$n" ] && n=0
    echo "$n"
    ;;
  list)
    # usage: list <offset> <limit>
    offset=${2:-0}
    limit=${3:-200}
    grep -e "^0\.0\.0\.0 " -e "^127\.0\.0\.1 " "$BLACKLIST" 2>/dev/null | tail -n "+$((offset + 1))" | head -n "$limit"
    ;;
  search)
    # usage: search <term> <limit>
    term="$2"
    limit=${3:-200}
    [ -z "$term" ] && exit 0
    grep -i -- "$term" "$BLACKLIST" 2>/dev/null | grep -e "^0\.0\.0\.0 " -e "^127\.0\.0\.1 " | head -n "$limit"
    ;;
  add)
    # usage: add <domain>
    ensure_files
    domain="$2"
    [ -z "$domain" ] && { echo "error: no domain"; exit 1; }
    if grep -qxF "127.0.0.1 $domain" "$USER_ADDED" 2>/dev/null; then
      echo exists
    else
      echo "127.0.0.1 $domain" >> "$USER_ADDED"
      esc=$(printf '%s' "$domain" | sed 's/[.[\*^$]/\\&/g')
      sed -i "/^${esc}$/d" "$USER_REMOVED" 2>/dev/null
      compile
      echo ok
    fi
    ;;
  remove)
    # usage: remove <domain>
    ensure_files
    domain="$2"
    [ -z "$domain" ] && { echo "error: no domain"; exit 1; }
    esc=$(printf '%s' "$domain" | sed 's/[.[\*^$]/\\&/g')
    sed -i "/^127\.0\.0\.1 ${esc}$/d" "$USER_ADDED" 2>/dev/null
    grep -qxF "$domain" "$USER_REMOVED" 2>/dev/null || echo "$domain" >> "$USER_REMOVED"
    compile
    echo ok
    ;;
  reset)
    # Wipe sources and manual edits, keep only the bundled default list.
    ensure_files
    find "$CACHE" -name 'src_*.txt' -delete 2>/dev/null
    : > "$SOURCES"
    : > "$USER_ADDED"
    : > "$USER_REMOVED"
    compile
    echo ok
    ;;
  src_list)
    ensure_files
    awk '{ print NR, $0 }' "$SOURCES" 2>/dev/null
    ;;
  src_add)
    # usage: src_add <url>
    ensure_files
    url="$2"
    [ -z "$url" ] && { echo "error: no url"; exit 1; }
    case "$url" in
      http://*|https://*) ;;
      *) echo "error: url must start with http:// or https://"; exit 1 ;;
    esac
    echo "$url" >> "$SOURCES"
    echo ok
    ;;
  src_remove)
    # usage: src_remove <line_number>
    ensure_files
    n="$2"
    [ -z "$n" ] && { echo "error: no line number"; exit 1; }
    sed -i "${n}d" "$SOURCES"
    echo ok
    ;;
  update)
    ensure_files
    ( run_update ) >/dev/null 2>&1 &
    echo started
    ;;
  update_status)
    cat "$UPDATE_STATUS" 2>/dev/null || echo none
    ;;
  *)
    echo "usage: $0 {status|enable|disable|count|list|search|add|remove|reset|src_list|src_add|src_remove|update|update_status}"
    exit 1
    ;;
esac
