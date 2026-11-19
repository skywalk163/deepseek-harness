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

# Identify the service by its exact argv, not by a substring of it.
#
# Two FreeBSD facts force this:
#   1. pgrep/pkill exclude themselves AND all of their direct ancestors unless
#      -a is given. This script is routinely run from inside a dsh session, so
#      the harness process is often an ancestor and silently would not match --
#      `status` reported a healthy service as down and `stop` claimed success
#      while leaving it running.
#   2. `-a` alone is not enough: `pkill -a -f "dsh:freebsd"` also matches any
#      shell whose command line merely mentions the string, so stopping the
#      service could kill an unrelated editing/ssh session.
#
# Matching the node process whose argv starts with `node <pnpm> dsh:freebsd`
# has neither problem: it is independent of who invoked the script, and it
# cannot match a shell that only talks about dsh:freebsd.
SERVICE_ARGV="node /usr/local/bin/pnpm dsh:freebsd"

# Print the pid of each service process, one per line.
service_pids() {
    for _p in $(ps -axo pid= 2>/dev/null); do
        [ "$(ps -p "$_p" -o comm= 2>/dev/null)" = "node" ] || continue
        case "$(ps -p "$_p" -o args= 2>/dev/null)" in
            "$SERVICE_ARGV"|"$SERVICE_ARGV "*) printf '%s\n' "$_p" ;;
        esac
    done
}

is_running() { [ -n "$(service_pids)" ]; }

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

# Print the pid of the running service when this script is itself a descendant
# of it, so `stop` and `restart` can warn that the caller's own session is about
# to end. The service cannot outlive the agent turn that asked to stop it, so
# saying so before the kill is the only chance the operator gets.
stop_targets_self() {
    _svc=$(service_pids | head -1)
    [ -n "$_svc" ] || return 1
    _p=$$
    while [ -n "$_p" ] && [ "$_p" -gt 1 ]; do
        [ "$_p" = "$_svc" ] && return 0
        _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
    done
    return 1
}

stop() {
    if is_running; then
        if stop_targets_self; then
            echo "note: this script is running inside dsh web (pid $(service_pids | head -1));"
            echo "      stopping the service ends the current session. Use rc.d or another shell to keep it."
        fi
        for _p in $(service_pids); do
            kill -TERM "$_p" 2>/dev/null
        done
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
    # stdin is redirected so the supervised process never inherits a descriptor
    # 0 that exists but cannot be stat'ed: the FreeBSD WebAssembly Sharp backend
    # fstat()s descriptors 0-2 while loading, and a bad one there used to abort
    # the service on the first image read. Keep this in step with dsh_web.rcd.
    /usr/sbin/daemon -p "$PIDFILE" -o "$LOG" /bin/sh -c "exec /bin/sh '$RUN' </dev/null"
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
        echo "RUNNING pid $(service_pids | head -1)"
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
