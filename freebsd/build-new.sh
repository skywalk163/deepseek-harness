#!/bin/sh
# Compile the updated dsh-jail-run.c (as workbuddy, into a writable path).
# Root install is left to the operator (setuid bit requires root).
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
cd "$REPO_ROOT" || exit 1
set -e
echo "=== compile ==="
cc -O2 -o /home/workbuddy/dsh-jail-run.new freebsd/dsh-jail-run.c -ljail
echo "compile_exit=$?"
ls -l /home/workbuddy/dsh-jail-run.new
echo "=== probe new binary: /workspace + /tmp ==="
W=$(mktemp -d /tmp/dsh-wtest-XXXX)
/home/workbuddy/dsh-jail-run.new --workspace "$W" --mode workspace-write -- bash -c 'printf OK > /workspace/inside.txt; echo ws=$?; printf TMP > /tmp/jtest.txt; echo tmp=$?; cat /tmp/jtest.txt'
echo "--- host checks ---"
ls -la "$W/inside.txt" 2>&1
echo -n "host /tmp/jtest.txt exists? "; ls /tmp/jtest.txt 2>&1 || true
rm -rf "$W"
