#!/bin/sh
# Run the standalone FreeBSD jail sandbox verification.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"
export DSH_JAIL_RUN_BIN=/var/dsh-jail-run
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
cd "$REPO_ROOT" || exit 1
exec node freebsd/verify-sandbox.mjs
