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

cd "$REPO_ROOT" || exit 1

# dsh:freebsd = dsh + --expose-internals (mandatory on FreeBSD for HMR service)
exec pnpm dsh:freebsd web
