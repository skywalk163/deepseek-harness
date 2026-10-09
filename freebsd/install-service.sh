#!/bin/sh
# ---------------------------------------------------------------------------
# install-service.sh -- install / remove the dsh_web rc.d service on FreeBSD.
#
# One-shot, idempotent installer for the FreeBSD port of DeepSeek Harness:
#   1. installs <repo>/freebsd/dsh_web.rcd as /usr/local/etc/rc.d/dsh_web
#   2. writes the required rc.conf variables, deriving the checkout's owner and
#      that owner's home directory from the repository itself -- no hand-editing
#      and no copy-pasting paths
#   3. optionally builds + installs the setuid jail sandbox helper
#   4. starts the service and waits until it answers on the loopback port
#
# Usage:
#   sh freebsd/install-service.sh [options]
#
#   (no options)           install, then start and verify
#   --no-start             install only; do not touch the running service
#   --restart              install, then restart instead of start
#   --projectdir <path>    default working directory for agent commands
#                          (dsh_web_projectdir; without it commands start in the
#                          repository root)
#   --port <n>             listen port (default 3080)
#   --user <name>          run the service as this user (default: the owner of
#                          the checkout directory)
#   --with-jail-helper     compile and install the setuid dsh-jail-run helper,
#                          which is what makes the confined permission modes
#                          work (see FREEBSD.md section 8.1)
#   --danger-full-access   put DSH_PERMISSION_MODE=danger-full-access into the
#                          service environment: the escape hatch for hosts where
#                          the jail helper cannot be installed. It DISABLES
#                          confinement.
#   --status               show the installed configuration and service state
#   --uninstall            stop the service and remove it from rc.conf
#   -h | --help            this help
#
# Environment overrides:
#   DSH_REPO=<path>        repository root (default: the parent directory of
#                          this script)
#
# Must run as root: it writes /usr/local/etc/rc.d and /etc/rc.conf. When invoked
# without root it re-executes itself through sudo(8) or doas(1) when either is
# available.
#
# Safe to re-run: an already-current rc.d script is left in place, and sysrc
# only rewrites variables whose value actually differs.
# ---------------------------------------------------------------------------

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

RC_NAME=dsh_web
RC_DEST="/usr/local/etc/rc.d/${RC_NAME}"
HELPER_DEFAULT=/var/dsh-jail-run
DEFAULT_PORT=3080

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'
}

# `--help` must work with neither root nor a checkout (you may be reading this
# straight out of a tarball), so it is answered before anything is validated.
for _a in "$@"; do
    case "$_a" in
        -h|--help) usage; exit 0 ;;
    esac
done

# --- resolve the repository root -------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) ||
    die "cannot resolve the directory holding this script"
REPO_ROOT=${DSH_REPO:-$(dirname -- "$SCRIPT_DIR")}
[ -f "$REPO_ROOT/pnpm-workspace.yaml" ] ||
    die "not a deepseek-harness checkout: $REPO_ROOT
       Run this script from <repo>/freebsd/, or set DSH_REPO=/path/to/repo."
RC_TEMPLATE="$REPO_ROOT/freebsd/dsh_web.rcd"
[ -f "$RC_TEMPLATE" ] || die "missing service template: $RC_TEMPLATE"

# --- elevate when needed (before parsing, so "$@" survives) -----------------
if [ "$(id -u)" -ne 0 ]; then
    for _elev in sudo doas; do
        if command -v "$_elev" >/dev/null 2>&1; then
            say "install-service: root is required; re-running through $_elev"
            exec "$_elev" env DSH_REPO="$REPO_ROOT" "$0" "$@"
        fi
    done
    die "root is required (install sudo or doas, or run this as root)"
fi

# --- options ---------------------------------------------------------------
MODE=install
DO_START=yes
DO_RESTART=no
PROJECTDIR=""
PORT=$DEFAULT_PORT
RUN_USER=""
WITH_HELPER=no
FULL_ACCESS=no

while [ $# -gt 0 ]; do
    case "$1" in
        --no-start)           DO_START=no ;;
        --start)              DO_START=yes ;;
        --restart)            DO_RESTART=yes ;;
        --projectdir)         shift; [ $# -gt 0 ] || die "--projectdir needs a path"; PROJECTDIR=$1 ;;
        --projectdir=*)       PROJECTDIR=${1#*=} ;;
        --port)               shift; [ $# -gt 0 ] || die "--port needs a number"; PORT=$1 ;;
        --port=*)             PORT=${1#*=} ;;
        --user)               shift; [ $# -gt 0 ] || die "--user needs a name"; RUN_USER=$1 ;;
        --user=*)             RUN_USER=${1#*=} ;;
        --with-jail-helper)   WITH_HELPER=yes ;;
        --danger-full-access) FULL_ACCESS=yes ;;
        --status)             MODE=status ;;
        --uninstall)          MODE=uninstall ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# --- who runs the service, and with which HOME -----------------------------
if [ -n "$RUN_USER" ]; then
    OWNER=$RUN_USER
else
    OWNER=$(stat -f '%Su' "$REPO_ROOT" 2>/dev/null)
fi
[ -n "$OWNER" ] || die "cannot determine the owner of $REPO_ROOT (pass --user)"

OWNER_HOME=$(pw usershow -n "$OWNER" 2>/dev/null | cut -d: -f9)
[ -n "$OWNER_HOME" ] || OWNER_HOME=$(eval "echo ~$OWNER" 2>/dev/null)
[ -n "$OWNER_HOME" ] || die "cannot determine the home directory of user '$OWNER'"

# rc.subr exports ${name}_env into the child (`env $_env`), so this is a
# space-separated VAR=value list. HOME must be pinned: `su -m` preserves the
# caller's environment, and without it pnpm would try to create
# /.local/share/pnpm and die with EACCES. See freebsd/dsh_web.rcd.
SVC_ENV="HOME=$OWNER_HOME"
[ "$FULL_ACCESS" = yes ] && SVC_ENV="$SVC_ENV DSH_PERMISSION_MODE=danger-full-access"
[ -n "$DSH_JAIL_RUN_BIN" ] && SVC_ENV="$SVC_ENV DSH_JAIL_RUN_BIN=$DSH_JAIL_RUN_BIN"

LOG_FILE="$REPO_ROOT/dsh_web.log"

rc_var() { sysrc -n "$1" 2>/dev/null || true; }

# Honour a port that is already configured, so a host installed on a non-default
# port is still probed on the right one when --port is not given.
if [ "$PORT" = "$DEFAULT_PORT" ]; then
    _rc_port=$(rc_var dsh_web_port)
    [ -n "$_rc_port" ] && PORT=$_rc_port
fi

set_rc_var() {
    _cur=$(rc_var "$1")
    if [ "$_cur" = "$2" ]; then
        say "  rc.conf  $1 = $2  (unchanged)"
    else
        sysrc "$1=$2" >/dev/null || die "sysrc $1 failed"
        say "  rc.conf  $1 = $2"
    fi
}

find_helper() {
    for _h in "$DSH_JAIL_RUN_BIN" "$HELPER_DEFAULT" /usr/local/sbin/dsh-jail-run; do
        [ -n "$_h" ] && [ -x "$_h" ] && { printf '%s' "$_h"; return 0; }
    done
    return 1
}

# --- preflight: what the service will need at runtime ----------------------
preflight() {
    _fatal=no

    if [ -x "$OWNER_HOME/.local/bin/pnpm" ]; then
        say "  pnpm     $OWNER_HOME/.local/bin/pnpm"
    elif [ -x /usr/local/bin/pnpm ]; then
        say "  pnpm     /usr/local/bin/pnpm"
        warn "no $OWNER_HOME/.local/bin/pnpm: the launcher will fall back to
       /usr/local/bin/pnpm. pnpm then re-creates its own managed copy under
       \$HOME/.local/share/pnpm on cold starts (slow, and it needs \$HOME)."
    else
        warn "pnpm not found for '$OWNER' (tried $OWNER_HOME/.local/bin/pnpm and
       /usr/local/bin/pnpm). Install it with npm -- see FREEBSD.md step 2."
        _fatal=yes
    fi

    if command -v node >/dev/null 2>&1; then
        say "  node     $(command -v node)"
    else
        warn "node not on PATH -- pkg install node24"
        _fatal=yes
    fi

    if ! command -v bash >/dev/null 2>&1; then
        warn "bash not found: the code/mini terminal backend requires it (pkg install bash)"
    fi

    if [ -d "$REPO_ROOT/node_modules" ]; then
        say "  deps     $REPO_ROOT/node_modules (present)"
    else
        warn "no node_modules in $REPO_ROOT -- run 'pnpm install' first"
        _fatal=yes
    fi

    if _helper=$(find_helper); then
        say "  sandbox  jail helper $_helper"
    else
        warn "no setuid jail helper found (looked at $HELPER_DEFAULT and
       /usr/local/sbin/dsh-jail-run). Without it the confined permission modes
       FAIL CLOSED and code/mini sessions abort. Fix with either:
         sh freebsd/install-service.sh --with-jail-helper    # build + install it
         sh freebsd/install-service.sh --danger-full-access  # run unconfined"
    fi

    [ "$_fatal" = no ] || return 1
    return 0
}

# --- actions ---------------------------------------------------------------
install_rc_script() {
    if [ -f "$RC_DEST" ] && cmp -s "$RC_TEMPLATE" "$RC_DEST"; then
        say "rc.d script already current: $RC_DEST"
    else
        install -o root -g wheel -m 0555 "$RC_TEMPLATE" "$RC_DEST" ||
            die "failed to install $RC_DEST"
        say "installed $RC_DEST (root:wheel, mode 0555)"
    fi
}

install_jail_helper() {
    _src="$REPO_ROOT/freebsd/dsh-jail-run.c"
    [ -f "$_src" ] || die "missing helper source: $_src"
    _cc=$(command -v cc || command -v clang)
    [ -n "$_cc" ] || die "no C compiler found (cc/clang); install the base toolchain"

    say "building the jail helper -> $HELPER_DEFAULT"
    "$_cc" -O2 -Wall -ljail -o "$HELPER_DEFAULT" "$_src" || die "helper compile failed"
    chown root:wheel "$HELPER_DEFAULT" || die "chown failed"
    chmod 4755 "$HELPER_DEFAULT" || die "chmod 4755 failed"
    ls -l "$HELPER_DEFAULT"

    # A nosuid mount would silently ignore the setuid bit and the helper would
    # look installed while never working.
    _mp=$(df -k "$HELPER_DEFAULT" 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -n "$_mp" ] && mount -p 2>/dev/null | awk -v m="$_mp" '$2==m {print $4}' | grep -q nosuid; then
        warn "$_mp is mounted nosuid: the setuid bit on $HELPER_DEFAULT will be
       ignored. Install the helper on a filesystem without nosuid instead."
    fi
}

# Never pipe `service` into another process. The daemonized harness child keeps
# the stdout it inherited open for the lifetime of the service, so the pipe never
# sees EOF and `... | sed` would block forever -- the install would look hung
# even though the service came up fine. Capture to a file, replay it indented.
run_service() {
    _tmp=$(mktemp -t dsh-install) || die "mktemp failed"
    service "$RC_NAME" "$@" >"$_tmp" 2>&1
    _rc=$?
    sed 's/^/  /' "$_tmp"
    rm -f "$_tmp"
    return $_rc
}

wait_for_port() {
    _i=0
    while [ "$_i" -lt "$1" ]; do
        if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
            return 0
        fi
        _i=$((_i + 1))
        sleep 1
    done
    return 1
}

show_token() {
    _url=$(grep -o 'http://127\.0\.0\.1:[0-9]*/?[^ ]*token=[A-Za-z0-9_-]*' "$LOG_FILE" 2>/dev/null | tail -1)
    [ -n "$_url" ] && say "auth URL: $_url"
}

do_status() {
    say "repository      : $REPO_ROOT"
    say "rc.d script     : $RC_DEST"
    if [ -f "$RC_DEST" ]; then
        ls -l "$RC_DEST"
    else
        say "                  NOT INSTALLED"
    fi
    say "rc.conf values:"
    for _v in dsh_web_enable dsh_web_chdir dsh_web_user dsh_web_env dsh_web_projectdir dsh_web_port; do
        _val=$(rc_var "$_v")
        say "  $_v = ${_val:-(unset)}"
    done
    say "helper          : $(find_helper || echo 'none')"
    say "log             : $LOG_FILE"
    say "service status:"
    run_service status
    if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
        say "listener        : 127.0.0.1:$PORT open"
        show_token
    else
        say "listener        : 127.0.0.1:$PORT closed"
    fi
}

do_uninstall() {
    say "stopping $RC_NAME"
    run_service stop
    rm -f "$REPO_ROOT/dsh_web.pid"

    for _v in dsh_web_enable dsh_web_chdir dsh_web_user dsh_web_env dsh_web_projectdir dsh_web_port; do
        if [ -n "$(rc_var "$_v")" ]; then
            sysrc -x "$_v" >/dev/null 2>&1 && say "  removed rc.conf $_v"
        fi
    done

    if [ -f "$RC_DEST" ]; then
        rm -f "$RC_DEST" && say "removed $RC_DEST"
    fi
    say "uninstalled. $LOG_FILE was kept; delete it manually if you want."
}

do_install() {
    say "repository : $REPO_ROOT"
    say "service user: $OWNER (home $OWNER_HOME)"
    say "environment : $SVC_ENV"
    say ""

    install_rc_script
    say "rc.conf:"
    set_rc_var dsh_web_enable YES
    set_rc_var dsh_web_chdir "$REPO_ROOT"
    set_rc_var dsh_web_user "$OWNER"
    set_rc_var dsh_web_env "$SVC_ENV"
    [ -n "$PROJECTDIR" ] && set_rc_var dsh_web_projectdir "$PROJECTDIR"
    [ "$PORT" != "$DEFAULT_PORT" ] && set_rc_var dsh_web_port "$PORT"
    say ""

    [ "$WITH_HELPER" = yes ] && install_jail_helper && say ""

    say "preflight:"
    preflight || warn "preflight found blocking problems (see above); continuing anyway"
    say ""

    if [ "$DO_START" = no ]; then
        say "done (--no-start). Start it later with: service $RC_NAME start"
        return 0
    fi

    _action=start
    [ "$DO_RESTART" = yes ] && _action=restart
    say "running: service $RC_NAME $_action"
    run_service "$_action"
    say ""

    if wait_for_port 60; then
        say "OK: $RC_NAME is listening on 127.0.0.1:$PORT"
        show_token
    else
        warn "$RC_NAME did not open 127.0.0.1:$PORT within 60s."
        warn "Check the log: tail -50 $LOG_FILE"
    fi
    say ""
    say "Remote access is loopback-only by design:"
    say "  ssh -L $PORT:127.0.0.1:$PORT $OWNER@<this-host>   then open http://localhost:$PORT"
}

case "$MODE" in
    install)   do_install ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
esac
