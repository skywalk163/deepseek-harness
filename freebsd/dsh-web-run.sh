#!/bin/sh
# Launcher for the DeepSeek harness (dsh) web UI.
# Lives in <repo>/freebsd/ and resolves the repo root from its own location,
# so it works no matter where the repo is cloned (no path editing required).
# Invoked by dsh-web-restart.sh and the rc.d service.

# FreeBSD now ships a real sandbox backend: the setuid `dsh-jail-run` jail
# helper is selected automatically by the local sandbox provider, so agent
# commands (code/mini/standard) run confined inside a jail instead of
# unconfined. We therefore do NOT force danger-full-access. Leave
# DSH_PERMISSION_MODE unset so the harness picks its default confined mode
# (read-only / workspace-write per session). Set DSH_PERMISSION_MODE=
# danger-full-access only as an explicit escape hatch when the helper cannot
# run on a given host.
if [ -n "${DSH_PERMISSION_MODE}" ]; then
  export DSH_PERMISSION_MODE
fi

# Path to the setuid jail helper. The default install location is
# /usr/local/sbin/dsh-jail-run; on hosts where /usr is a read-only mount
# (this one) install it under /var instead and point here. See FREEBSD.md.
export DSH_JAIL_RUN_BIN="${DSH_JAIL_RUN_BIN:-/var/dsh-jail-run}"

# Make sure node/pnpm (from /usr/local) and the gmake shim (~/bin/make) are
# found, whether launched from an interactive shell or at boot via rc.d
# (where PATH is minimal). Do NOT rely on /tmp/p117-style paths.
export PATH="$HOME/bin:/usr/local/bin:/usr/local/sbin:$PATH"

# Resolve repo root: parent of this script's directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")

# Project directory: the default working directory for every bash/grep/terminal
# command. The harness routes a command's cwd through session.header.cwd, which
# falls back to process.cwd() (this script's cwd) when the web UI does not set a
# per-task project directory. On FreeBSD the web fork does not yet wire the
# task "项目目录" field into header.cwd, so set DSH_PROJECT_DIR here to make your
# project the default — otherwise it defaults to the repo root.
cd "${DSH_PROJECT_DIR:-$REPO_ROOT}" || exit 1

# dsh:freebsd = dsh + --expose-internals (mandatory on FreeBSD for HMR service)
exec pnpm dsh:freebsd web
