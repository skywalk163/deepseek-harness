#!/bin/sh
# Direct binary check: /workspace write + /tmp ephemeral write + host leakage.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"
export DSH_JAIL_RUN_BIN=/var/dsh-jail-run
W=$(mktemp -d /tmp/dsh-wtest-XXXX)
echo "W=$W"
echo '--- write to /workspace ---'
/var/dsh-jail-run --workspace "$W" --mode workspace-write -- bash -c 'printf OK > /workspace/inside.txt; echo ws_status=$?; ls -la /workspace/inside.txt; cat /workspace/inside.txt'
echo '--- write to /tmp (ephemeral) ---'
/var/dsh-jail-run --workspace "$W" --mode workspace-write -- bash -c 'printf TMP > /tmp/jtest.txt; echo tmp_status=$?; ls -la /tmp/jtest.txt 2>&1; cat /tmp/jtest.txt 2>&1'
echo '--- host checks ---'
echo "host workspace file:"; ls -la "$W/inside.txt" 2>&1
echo "host /tmp/jtest.txt exists?"; ls -la /tmp/jtest.txt 2>&1
rm -rf "$W"
