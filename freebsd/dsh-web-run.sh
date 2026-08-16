#!/bin/sh
# Launcher for the DeepSeek harness (dsh) web UI.
# Lives in <repo>/freebsd/ and resolves the repo root from its own location,
# so it works no matter where the repo is cloned (no path editing required).
# Invoked by dsh-web-restart.sh and the rc.d service.

# Run unconfined: FreeBSD has no sandbox backend (confinement supports only
# Linux/macOS/Windows), so it fails closed otherwise. Override with the env var
# if you really want a different mode.
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"

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
