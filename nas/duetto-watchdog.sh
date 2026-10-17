#!/bin/sh
# Duetto stream watchdog for a Synology NAS.
#
# Internet radio streams sometimes stall and the Duetto doesn't reconnect by
# itself. This script checks the radio and, if internet radio has been stopped
# or failed (or stuck buffering) for a while, restarts it with a quick power
# off/on, which makes the radio reconnect to the same station.
#
# It also catches "silent" stalls, where the radio still says it's playing:
# while audio flows, the play position counts up; when the stream stalls it
# stops moving. Two identical readings 15 s to 2 min apart count as a stall.
#
# Run it from DSM's Task Scheduler every minute; each run checks twice,
# 30 seconds apart (so a run takes about 30 s and runs never overlap).
# It does nothing when the radio is off (standby), on another source, or
# unreachable. A log is kept next to this script.
#
# Presets: the Duetto sometimes loses its Internet Radio presets while it's
# switched off or after a power cut. When the radio comes on, the script reads
# the presets: if they're intact it saves a backup next to this script
# (duetto-presets.backup); if they've ALL gone it mutes the radio, finds each
# station in the radio's directory, saves it back into its slot, returns to
# what was playing and unmutes. The backup is never overwritten by a shorter
# list, and is refreshed once an hour while the radio is on so it stays current.
# Delete duetto-presets.backup to start the backup afresh.

RADIO="${RADIO:-192.168.100.102}"           # the radio's reserved address
PIN="${PIN:-1234}"                          # the radio's remote PIN
STOPPED_AFTER="${STOPPED_AFTER:-30}"        # seconds a stopped/failed stream is tolerated
BUFFERING_AFTER="${BUFFERING_AFTER:-90}"    # seconds of continuous buffering tolerated
COOLDOWN="${COOLDOWN:-300}"                 # at least this many seconds between restarts
CHECKS="${CHECKS:-2}"                       # checks per run...
GAP="${GAP:-30}"                            # ...this many seconds apart
AUTO_RESTORE="${AUTO_RESTORE:-1}"           # 1 = put presets back automatically after a wipe, 0 = only log it
BACKUP_REFRESH="${BACKUP_REFRESH:-3600}"    # while on, re-read presets this often (seconds) to keep the backup current

DIR=$(cd "$(dirname "$0")" && pwd)
STATE="$DIR/duetto-watchdog.state"
LOG="$DIR/duetto-watchdog.log"
BACKUP="$DIR/duetto-presets.backup"          # one "slot<TAB>station" line per preset
PSTATE="$DIR/duetto-watchdog.presets"        # last_power last_seen pending last_read last_count
FIRMWARE="$DIR/duetto-watchdog.firmware"
LOCK="$DIR/.duetto-watchdog.lock"
T=$(printf '\t')

# Only one run at a time: restoring presets can take a minute or two, longer
# than the gap between scheduled runs.
if ! mkdir "$LOCK" 2>/dev/null; then
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 0   # still busy: skip this run
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0                     # left behind by a crash: take it over
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# Reads one numeric setting from the radio; prints nothing if it can't.
get() {
  curl -s --max-time 4 "http://$RADIO/fsapi/GET/$1?pin=$PIN" | tr -d '\r\n' |
    sed -n 's:.*<status>FS_OK</status>.*<value><[a-z0-9_]*>\(-\{0,1\}[0-9][0-9]*\)</[a-z0-9_]*></value>.*:\1:p'
}
put() { curl -s --max-time 4 "http://$RADIO/fsapi/SET/$1?pin=$PIN&value=$2" >/dev/null; }

# --- Text settings, lists and menu navigation (used for presets) -------------
decode() { sed "s/&lt;/</g; s/&gt;/>/g; s/&quot;/\"/g; s/&apos;/'/g; s/&#39;/'/g; s/&amp;/\\&/g"; }

# Reads one text setting (e.g. the station name); prints nothing if it can't.
get_text() {
  curl -s --max-time 4 "http://$RADIO/fsapi/GET/$1?pin=$PIN" | tr -d '\r\n' |
    sed -n 's:.*<status>FS_OK</status>.*<value><c8_array>\([^<]*\)</c8_array></value>.*:\1:p' | decode
}
# Sends a command; succeeds only if the radio answers FS_OK.
put_ok() { curl -s --max-time 4 "http://$RADIO/fsapi/SET/$1?pin=$PIN&value=$2" | grep -q FS_OK; }
put_text() {   # same, for text values (the radio needs them URL-encoded)
  curl -s --max-time 4 -G "http://$RADIO/fsapi/SET/$1" --data-urlencode "pin=$PIN" --data-urlencode "value=$2" | grep -q FS_OK
}

# Prints a radio list as "key<TAB>type<TAB>name" lines (type: 0 folder, 1 station, 2 search).
nav_list() {
  { curl -s --max-time 8 "http://$RADIO/fsapi/LIST_GET_NEXT/$1/-1?pin=$PIN&maxItems=60" | tr -d '\r\n'; echo; } |
    sed 's/<item /\
<item /g' | while IFS= read -r line; do
      case "$line" in '<item key="'*) ;; *) continue ;; esac
      key=$(printf '%s' "$line" | sed -n 's/^<item key="\([0-9]*\)".*/\1/p')
      name=$(printf '%s' "$line" | sed -n 's:.*<field name="name"><c8_array>\([^<]*\)</c8_array>.*:\1:p' | decode)
      type=$(printf '%s' "$line" | sed -n 's:.*<field name="type"><u8>\([0-9]*\)</u8>.*:\1:p')
      printf '%s\t%s\t%s\n' "$key" "${type:-0}" "$name"
    done
}

# After moving in the menu the radio fetches the folder from its station service.
wait_ready() {
  local i s
  i=0
  while [ "$i" -lt 30 ]; do
    s=$(get netRemote.nav.status)
    [ -z "$s" ] && { sleep 1; return 0; }   # not reported by this radio: just give it a moment
    case "$s" in 1|4) return 0 ;; 2|3) return 1 ;; esac
    sleep 1; i=$((i + 1))
  done
  return 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Prints the key of the directory's station search, leaving the menu there.
find_search() {
  local list k
  put_ok netRemote.nav.state 0; put_ok netRemote.nav.state 1 || return 1
  wait_ready || return 1
  list=$(nav_list netRemote.nav.list)
  k=$(printf '%s\n' "$list" | awk -F"$T" '$2==2 {print $1; exit}')
  if [ -z "$k" ]; then   # usually inside "Stations"
    k=$(printf '%s\n' "$list" | awk -F"$T" '$2==0 && tolower($3)=="stations" {print $1; exit}')
    [ -n "$k" ] || return 1
    put_ok netRemote.nav.action.navigate "$k" || return 1
    wait_ready || return 1
    k=$(nav_list netRemote.nav.list | awk -F"$T" '$2==2 {print $1; exit}')
  fi
  [ -n "$k" ] && printf '%s\n' "$k"
}

# Searches for a station by its exact name and plays it; waits until it's playing.
play_by_name() {
  local s k i want
  want=$(lower "$1")
  s=$(find_search) || return 1
  put_text netRemote.nav.searchTerm "$1" || return 1
  put_ok netRemote.nav.action.navigate "$s" || return 1
  wait_ready || return 1
  k=$(nav_list netRemote.nav.list | while IFS="$T" read -r key type name; do
        [ "$type" = 1 ] && [ "$(lower "$name")" = "$want" ] && { echo "$key"; break; }
      done)
  [ -n "$k" ] || return 1
  put_ok netRemote.nav.action.selectItem "$k" || return 1
  i=0
  while [ "$i" -lt 15 ]; do
    sleep 1
    [ "$(get netRemote.play.status)" = 2 ] && [ "$(lower "$(get_text netRemote.play.info.name)")" = "$want" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# Writes the Internet Radio preset slots to $1 as "slot<TAB>station" (empty name = empty slot).
read_presets() {
  put_ok netRemote.nav.state 1 || return 1
  nav_list netRemote.nav.presets | while IFS="$T" read -r k ty n; do printf '%s\t%s\n' "$k" "$n"; done > "$1"
  [ -s "$1" ]
}
named() { awk -F"$T" '$2!="" {c++} END {print c+0}' "$1"; }

restore_presets() {
  local was_muted was_playing total restored failed k n
  was_muted=$(get netRemote.sys.audio.mute)
  was_playing=$(get_text netRemote.play.info.name)
  put_ok netRemote.sys.audio.mute 1          # no station-hopping noise while it works
  total=0; restored=0; failed=""
  while IFS="$T" read -r k n <&3; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    if play_by_name "$n" && put_ok netRemote.play.addPreset "$k"; then restored=$((restored + 1))
    else failed="$failed${failed:+, }$n"; fi
  done 3< "$BACKUP"
  # Back to what was playing, if it's one of the presets.
  k=$(while IFS="$T" read -r kk nn; do [ "$(lower "$nn")" = "$(lower "$was_playing")" ] && { echo "$kk"; break; }; done < "$BACKUP")
  if [ -n "$k" ]; then put_ok netRemote.nav.state 1; put_ok netRemote.nav.action.selectPreset "$k"; fi
  [ "$was_muted" = 1 ] || put_ok netRemote.sys.audio.mute 0
  if [ -n "$failed" ]; then log "Restored $restored of $total presets (couldn't find: $failed)"
  else log "Restored $restored of $total presets"; fi
}

# Reads the presets; updates the backup, or restores after a wipe. Uses/sets $last_count.
check_presets() {
  local cur n b
  cur="$DIR/.duetto-presets.now"
  read_presets "$cur" || { rm -f "$cur"; return 1; }
  n=$(named "$cur"); b=0
  [ -s "$BACKUP" ] && b=$(named "$BACKUP")
  if [ "$n" -gt 0 ] && [ "$n" -ge "$b" ]; then
    awk -F"$T" '$2!=""' "$cur" > "$BACKUP.new"
    if [ "$(cat "$BACKUP.new")" != "$(cat "$BACKUP" 2>/dev/null)" ]; then
      mv "$BACKUP.new" "$BACKUP"; log "Saved backup of $n Internet Radio presets"
    else rm -f "$BACKUP.new"; fi
  elif [ "$n" = 0 ] && [ "$b" -gt 0 ]; then
    if [ "$AUTO_RESTORE" = 1 ]; then
      log "Internet Radio presets: $b → 0, restoring from backup"
      restore_presets
      read_presets "$cur" && n=$(named "$cur")
    else log "Internet Radio presets: $b → 0 (automatic restore is off)"; fi
  elif [ "$n" -lt "$b" ] && [ "$n" != "$last_count" ]; then   # say so once, not every hour
    log "Internet Radio presets: $b → $n (only some missing, so not restoring automatically; the page's Restore can put them back)"
  fi
  last_count=$n
  rm -f "$cur"
}

check_firmware() {
  local v old
  v=$(get_text netRemote.sys.info.version)
  [ -n "$v" ] || return 0
  old=$(cat "$FIRMWARE" 2>/dev/null)
  if [ "$v" != "$old" ]; then
    [ -n "$old" ] && log "Firmware changed from $old to $v"
    printf '%s\n' "$v" > "$FIRMWARE"
  fi
}

source_name() {
  case "$1" in
    0) echo "Internet Radio" ;; 1) echo "Spotify" ;; 3) echo "USB" ;; 4) echo "FM" ;;
    5) echo "Bluetooth" ;; 6) echo "Aux" ;; *) echo "source $1" ;;
  esac
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"   # keep it short
}

check() {
  now=$(date +%s)
  bad_since=0; last_restart=0
  [ -f "$STATE" ] && read -r bad_since last_restart < "$STATE"
  : "${bad_since:=0}" "${last_restart:=0}"
  last_pos=-1; last_pos_at=0
  [ -f "$STATE.pos" ] && read -r last_pos last_pos_at < "$STATE.pos"
  : "${last_pos:=-1}" "${last_pos_at:=0}"

  power=$(get netRemote.sys.power)
  mode=$(get netRemote.sys.mode)
  status=$(get netRemote.play.status)
  pos=$(get netRemote.play.position)       # milliseconds since the stream started

  # --- Presets: check when the radio has just come on, and hourly to keep the backup current ---
  prev_power=""; prev_seen=0; pending=0; last_read=0; last_count=""
  [ -f "$PSTATE" ] && read -r prev_power prev_seen pending last_read last_count < "$PSTATE"
  : "${prev_seen:=0}" "${pending:=0}" "${last_read:=0}"
  [ "$prev_power" = - ] && prev_power=""
  presets_done=0
  if [ "$power" = 1 ]; then
    # "Just came on": off/unreachable last time, or not seen for 10+ minutes.
    if [ "$prev_power" != 1 ] || [ $((now - prev_seen)) -gt 600 ]; then pending=1; check_firmware; fi
    if [ "$mode" = 0 ] && { [ "$pending" = 1 ] || [ $((now - last_read)) -ge "$BACKUP_REFRESH" ]; }; then
      if check_presets; then pending=0; last_read=$now; presets_done=1; fi
    fi
  fi
  echo "${power:--} $now $pending $last_read ${last_count:--}" > "$PSTATE"
  if [ "$presets_done" = 1 ]; then     # the menu was busy: leave stream checks to the next round
    echo "-1 0" > "$STATE.pos"
    return
  fi

  # play.status: 1 buffering, 2 playing, 3 paused, 4 rebuffering, 5 error, 6 stopped
  case "$status" in
    5|6) kind=stopped; limit=$STOPPED_AFTER ;;
    1|4) kind=buffering; limit=$BUFFERING_AFTER ;;
    *)   kind=ok ;;
  esac

  # Silent stall: "playing", but the position hasn't moved since the last check.
  if [ "$power" = 1 ] && [ "$mode" = 0 ] && [ "$status" = 2 ] && [ -n "$pos" ]; then
    age=$((now - last_pos_at))
    if [ "$pos" = "$last_pos" ] && [ "$last_pos_at" != 0 ] && [ "$age" -ge 15 ] && [ "$age" -le 120 ]; then
      if [ $((now - last_restart)) -ge "$COOLDOWN" ]; then
        log "Stream silent: says playing but position stuck at $pos for $age s, restarting (power off/on)"
        put netRemote.sys.power 0
        sleep 2
        put netRemote.sys.power 1
        echo "0 $now" > "$STATE"
        echo "-1 0" > "$STATE.pos"
        return
      fi
    elif [ "$pos" != "$last_pos" ] || [ "$age" -gt 120 ]; then
      echo "$pos $now" > "$STATE.pos"      # moving (or an old reading): remember it
    fi
  else
    echo "-1 0" > "$STATE.pos"
  fi

  # Only internet radio (mode 0), only while switched on, only when there's a problem.
  if [ "$power" != 1 ] || [ "$mode" != 0 ] || [ "$kind" = ok ]; then
    if [ "$bad_since" != 0 ]; then   # say why we stopped watching
      if [ -z "$power" ]; then log "Stopped watching: radio unreachable"
      elif [ "$power" != 1 ]; then log "Stopped watching: radio switched off"
      elif [ "$mode" != 0 ]; then log "Stopped watching: source changed to $(source_name "$mode")"
      else log "Stream is fine again"
      fi
    fi
    echo "0 $last_restart" > "$STATE"
    return
  fi

  if [ "$bad_since" = 0 ]; then
    log "Stream $kind (status $status), watching"
    echo "$now $last_restart" > "$STATE"
    return
  fi

  if [ $((now - bad_since)) -ge "$limit" ] && [ $((now - last_restart)) -ge "$COOLDOWN" ]; then
    log "Stream $kind for $((now - bad_since)) s, restarting (power off/on)"
    put netRemote.sys.power 0
    sleep 2
    put netRemote.sys.power 1
    echo "0 $now" > "$STATE"
  else
    echo "$bad_since $last_restart" > "$STATE"
  fi
}

i=1
while :; do
  check
  [ "$i" -ge "$CHECKS" ] && break
  i=$((i + 1))
  sleep "$GAP"
done
