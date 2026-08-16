#!/bin/sh
# Restart / stop / start / status the dsh web UI.
# Usage: sh freebsd/dsh-web-restart.sh [stop|start|restart|status]   (default: restart)
# Every path is resolved from this script's own location, so it works no matter
# where the repo is cloned (no editing required).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
PIDFILE="$REPO_ROOT/dsh_web.pid"
LOG="$REPO_ROOT/dsh_web.log"
RUN="$SCRIPT_DIR/dsh-web-run.sh"
PORT=3080

is_running() { pgrep -f "[d]sh:freebsd" >/dev/null 2>&1; }

stop() {
  if is_running; then
    pkill -f "[d]sh:freebsd"
    echo "sent TERM to dsh web"
  else
    echo "not running"
  fi
  rm -f "$PIDFILE"
}

start() {
  if is_running; then
    echo "already running; use restart to relaunch"
    return 0
  fi
  /usr/sbin/daemon -p "$PIDFILE" -o "$LOG" /bin/sh "$RUN"
  sleep 3
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" 2>/dev/null)
  echo "http status: ${code:-n/a}   (log: tail -f $LOG)"
}

status() {
  if is_running; then
    echo "RUNNING pid $(pgrep -f '[d]sh:freebsd' | head -1)"
    sockstat -l -p "$PORT" 2>/dev/null | grep -q node && echo "listening on :$PORT"
  else
    echo "NOT running"
  fi
}

case "${1:-restart}" in
  stop) stop ;;
  start) start ;;
  status) status ;;
  restart|*) stop; sleep 2; start ;;
esac
