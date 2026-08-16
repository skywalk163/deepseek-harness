#!/bin/sh
# Run the freebsd-jail e2e test via the repo-root e2e vitest config.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"
export DSH_JAIL_RUN_BIN=/var/dsh-jail-run
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
cd "$REPO_ROOT" || exit 1
exec pnpm vitest run --config vitest.e2e.config.ts packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts
