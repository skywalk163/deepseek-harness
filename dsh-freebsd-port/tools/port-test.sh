#!/bin/sh
# port-test.sh — exercise the deepseek-harness port on a live FreeBSD box.
# Self-logging + detached, same pattern as the other tools.
if [ "${1:-}" != "fg" ]; then
  nohup sh "$0" fg > /tmp/port-test-run.log 2>&1 &
  echo "launched (pid $!); tail -f /tmp/port-test-run.log"
  exit 0
fi

PORTDIR=/tmp/dsh-port/devel/deepseek-harness
DISTDIR=/home/workbuddy/dsh-port-dist

echo "== port tree:"
ls "$PORTDIR"
echo "== distfile:"
ls -la "$DISTDIR"/*.tar.gz

echo "== make checksum"
make -C "$PORTDIR" DISTDIR="$DISTDIR" ALLOW_UNSUPPORTED_SYSTEM=yes checksum || { echo "CHECKSUM-FAIL"; exit 1; }

echo "== make stage"
make -C "$PORTDIR" DISTDIR="$DISTDIR" ALLOW_UNSUPPORTED_SYSTEM=yes stage || { echo "STAGE-FAIL"; exit 1; }

echo "== staged tree (top):"
find "$PORTDIR/work/stage" -maxdepth 3 | head -20

echo "== staged wrapper (bin/dsh):"
cat "$PORTDIR/work/stage/usr/local/bin/dsh"

echo "== staged rc.d:"
ls -la "$PORTDIR/work/stage/usr/local/etc/rc.d/" 2>/dev/null
head -5 "$PORTDIR/work/stage/usr/local/etc/rc.d/dsh_web" 2>/dev/null

echo "== staged jail helper:"
ls -la "$PORTDIR/work/stage/usr/local/libexec/dsh-jail-run"

echo "== make check-plist"
make -C "$PORTDIR" DISTDIR="$DISTDIR" ALLOW_UNSUPPORTED_SYSTEM=yes check-plist || { echo "CHECKPLIST-FAIL (see output above)"; exit 1; }

echo "PORT-TEST-DONE"
