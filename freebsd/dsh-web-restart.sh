#!/bin/sh
# Restart / stop / start / status the dsh web UI.
# Usage: sh freebsd/dsh-web-restart.sh [stop|start|restart|status]   (default: restart)
# Surfaces the generated auth token so the operator can open the web UI.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
PIDFILE="$REPO_ROOT/dsh_web.pid"
LOG="$REPO_ROOT/dsh_web.log"
RUN="$SCRIPT_DIR/dsh-web-run.sh"
PORT=3080

is_running() { pgrep -f "[d]sh:freebsd" >/dev/null 2>&1; }

current_token() {
    grep -oE "token=[A-Za-z0-9_-]+" "$LOG" 2>/dev/null | tail -1 | cut -d= -f2-
}

wait_new_token() {
    local i token start_line="$1"
    for i in $(seq 1 45); do
        token=$(tail -n +"$start_line" "$LOG" 2>/dev/null | grep -oE "token=[A-Za-z0-9_-]+" | tail -1 | cut -d= -f2-)
        if [ -n "$token" ]; then break; fi
        sleep 1
    done
    echo "$token"
}

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
    before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    before=$((before + 1))
    /usr/sbin/daemon -p "$PIDFILE" -o "$LOG" /bin/sh "$RUN"
    token=$(wait_new_token "$before")
    if [ -n "$token" ]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "http://127.0.0.1:${PORT}/?token=${token}" 2>/dev/null)
        echo "http status: ${code:-n/a}   (token verified)"
        echo "Open:  http://127.0.0.1:${PORT}/?token=${token}"
    else
        echo "token not found yet; check $LOG"
    fi
}

status() {
    if is_running; then
        echo "RUNNING pid $(pgrep -f '[d]sh:freebsd' | head -1)"
        sockstat -l -p "$PORT" 2>/dev/null | grep -q node && echo "listening on :$PORT"
        echo "Open:  http://127.0.0.1:${PORT}/?token=$(current_token)"
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
