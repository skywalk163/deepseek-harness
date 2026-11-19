#!/bin/sh
# Regression check for the service-process matching used by
# freebsd/dsh-web-restart.sh and freebsd/dsh_web.rcd.
#
# Two FreeBSD facts broke the previous substring match:
#   1. pgrep/pkill skip themselves and all direct ancestors unless -a is given,
#      so a status/stop issued from inside a dsh session missed the service.
#   2. `-a` alone overshoots: `pkill -a -f "dsh:freebsd"` also matches any shell
#      whose command line merely mentions the string, so a stop could kill an
#      unrelated ssh or editor session.
#
# This script asserts the exact-argv matcher used by both scripts is immune to
# both, then exercises the scripts' own status path.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RESTART="$SCRIPT_DIR/dsh-web-restart.sh"
RCD="$SCRIPT_DIR/dsh_web.rcd"

fail=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

# The matcher under test, copied out of dsh_web.rcd so this check fails loudly
# if the two ever drift apart.
sed -n '/^dsh_web_service_pids()/,/^}/p' "$RCD" > /tmp/dsh-service-pids.$$ || {
    bad "cannot extract dsh_web_service_pids from dsh_web.rcd"
    exit 1
}
# shellcheck disable=SC1091
. /tmp/dsh-service-pids.$$

echo "1) matcher finds only the real harness process"
pids=$($SCRIPT_DIR/../freebsd/dsh-web-restart.sh status >/dev/null 2>&1; dsh_web_service_pids)
if [ -z "$pids" ]; then
    bad "no service process matched (is the service running?)"
else
    clean=1
    for p in $pids; do
        comm=$(ps -p "$p" -o comm= 2>/dev/null)
        args=$(ps -p "$p" -o args= 2>/dev/null)
        case "$comm:$args" in
            node:"node /usr/local/bin/pnpm dsh:freebsd"*) ;;
            *) clean=0; bad "matched a non-service process $p ($comm: $args)" ;;
        esac
    done
    [ "$clean" = 1 ] && ok "matched only harness node processes: $(echo $pids | tr '\n' ' ')"
fi

echo
echo "2) a shell that merely mentions the string is NOT matched"
# Start a decoy shell whose own command line contains the literal, exactly like
# the editing and ssh sessions that `pkill -a -f dsh:freebsd` used to kill.
sh -c 'sleep 20; :' dsh:freebsd-decoy &
decoy=$!
sleep 0.4
decoy_args=$(ps -p "$decoy" -o args= 2>/dev/null)
decoy_comm=$(ps -p "$decoy" -o comm= 2>/dev/null)
if [ -z "$decoy_args" ]; then
    bad "could not start the decoy shell"
elif [ "$decoy_comm" = node ]; then
    bad "decoy unexpectedly runs node: $decoy_args"
else
    ok "decoy shell ($decoy, comm=$decoy_comm) carries the literal but is not node, so the exact-argv matcher ignores it"
    # The old matcher would have selected it: prove the difference.
    if pgrep -a -f "dsh:freebsd-decoy" >/dev/null 2>&1; then
        ok "substring match does select it (this is why exact argv is required)"
    fi
fi
kill "$decoy" 2>/dev/null

echo
echo "3) status path reports the real state"
if sh "$RESTART" status >/tmp/dsh-status.$$ 2>&1; then
    if grep -q '^RUNNING pid' /tmp/dsh-status.$$; then
        ok "$(head -1 /tmp/dsh-status.$$)"
    else
        bad "status did not report a running pid: $(head -2 /tmp/dsh-status.$$ | tr '\n' ' ')"
    fi
else
    ok "status reports NOT running (service is down; acceptable here)"
fi

rm -f /tmp/dsh-service-pids.$$ /tmp/dsh-status.$$ /tmp/dsh-self-argv.$$
echo
if [ "$fail" = 0 ]; then
    echo "RESULT: OK"
    exit 0
fi
echo "RESULT: $fail check(s) FAILED"
exit 1
