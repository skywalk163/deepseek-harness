#!/bin/sh
# wrap-test2.sh — install the port to a custom PREFIX and exercise the wrapper.
if [ "${1:-}" != "fg" ]; then
  nohup sh "$0" fg > /tmp/wrap2-run.log 2>&1 &
  echo "launched (pid $!)"
  exit 0
fi

PORTDIR=/tmp/dsh-port/devel/deepseek-harness
DISTDIR=/home/workbuddy/dsh-port-dist
PREFIX=/tmp/dshtest

echo "== make install PREFIX=$PREFIX"
make -C "$PORTDIR" DISTDIR="$DISTDIR" ALLOW_UNSUPPORTED_SYSTEM=yes install PREFIX="$PREFIX" 2>&1 | tail -8

echo "== installed layout =="
ls "$PREFIX/bin/" 2>/dev/null
ls -la "$PREFIX/etc/rc.d/dsh_web" 2>/dev/null
ls -la "$PREFIX/libexec/dsh-jail-run" 2>/dev/null

echo "== wrapper: dsh --help (first 12 lines) =="
"$PREFIX/bin/dsh" --help 2>&1 | head -12

echo "WRAPTEST2-DONE"
