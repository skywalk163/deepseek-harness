#!/bin/sh
# One-shot host-lib rebuild for the FreeBSD jail sandbox work.
# Resolves the repo root from its own location and uses the persisted pnpm.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
cd "$REPO_ROOT" || exit 1
echo BUILD_START
pnpm run build:lib:host 2>&1 | tail -60
echo BUILD_DONE_RC=$?
