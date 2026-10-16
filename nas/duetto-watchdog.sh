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
# 30 seconds apart. It does nothing when the radio is off (standby), on another
# source, or unreachable. A log is kept next to this script.

RADIO="${RADIO:-192.168.100.102}"           # the radio's reserved address
PIN="${PIN:-1234}"                          # the radio's remote PIN
STOPPED_AFTER="${STOPPED_AFTER:-30}"        # seconds a stopped/failed stream is tolerated
BUFFERING_AFTER="${BUFFERING_AFTER:-90}"    # seconds of continuous buffering tolerated
COOLDOWN="${COOLDOWN:-300}"                 # at least this many seconds between restarts
CHECKS="${CHECKS:-2}"                       # checks per run...
GAP="${GAP:-30}"                            # ...this many seconds apart

DIR=$(cd "$(dirname "$0")" && pwd)
STATE="$DIR/duetto-watchdog.state"
LOG="$DIR/duetto-watchdog.log"

# Reads one numeric setting from the radio; prints nothing if it can't.
get() {
  curl -s --max-time 4 "http://$RADIO/fsapi/GET/$1?pin=$PIN" | tr -d '\r\n' |
    sed -n 's:.*<status>FS_OK</status>.*<value><[a-z0-9_]*>\(-\{0,1\}[0-9][0-9]*\)</[a-z0-9_]*></value>.*:\1:p'
}
put() { curl -s --max-time 4 "http://$RADIO/fsapi/SET/$1?pin=$PIN&value=$2" >/dev/null; }

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
    [ "$bad_since" != 0 ] && [ "$power" = 1 ] && log "Stream is fine again"
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
