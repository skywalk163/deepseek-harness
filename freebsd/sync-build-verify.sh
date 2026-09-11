#!/bin/sh
# ---------------------------------------------------------------------------
# dsh FreeBSD fork —— 上游同步后的「构建 + 自检」一键脚本
#
# 在 FreeBSD 主机上以「仓库属主」身份运行（1.5 = workbuddy，0.88 = skywalk）。
#
# 用法:
#   sh freebsd/sync-build-verify.sh [repo_root]
#
# ssh 通道下必须后台跑（长构建会把通道写爆 -> SIGPIPE 杀掉脚本）:
#   nohup sh freebsd/sync-build-verify.sh > /tmp/sync.out 2>&1 </dev/null &
#   tail -f /tmp/sync.out
#
# 退出码: 0 = 全绿 / 1 = 构建失败 / 2 = 用法或环境错误
#
# 覆盖的已知坑:
#   * 合并上游后必须先 clean（陈旧 lib/ 会让 tsdown 报 MISSING_EXPORT）
#   * clean 后首次 build:lib 在 1.5(8GB) 上可能 OOM(exit 137)
#     -> 自动重跑一次，走 tsbuildinfo 增量续编
#   * 原生 flock 插件每台机器各自编译（packages/*/bin/ 不入库）
# ---------------------------------------------------------------------------
set -u

REPO="${1:-${DSH_REPO:-}}"
if [ -z "$REPO" ]; then
  for c in "$HOME/github/deepseek-harness" /home/*/github/deepseek-harness; do
    if [ -d "$c/.git" ]; then REPO="$c"; break; fi
  done
fi
if [ -z "$REPO" ] || [ ! -d "$REPO/.git" ]; then
  echo "FATAL: 找不到仓库根，请显式传入：sh $0 /path/to/deepseek-harness" >&2
  exit 2
fi
cd "$REPO" || exit 2

export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/local/sbin:$PATH"
export DSH_JAIL_RUN_BIN="${DSH_JAIL_RUN_BIN:-/var/dsh-jail-run}"

LOG="${DSH_SYNC_LOG:-/tmp/dsh-sync-build.$(id -u).log}"
: > "$LOG" 2>/dev/null || LOG="/tmp/dsh-sync-build.$$.log"

say() { printf '%s\n' "$*"; }

step() {   # step <名字> <命令...>
  name="$1"; shift
  printf '\n===== %s =====\n' "$name" >>"$LOG"
  "$@" >>"$LOG" 2>&1
  rc=$?
  line=$(printf 'EXIT %-18s = %s' "$name" "$rc")
  printf '%s\n' "$line" >>"$LOG"
  printf '%s\n' "$line"
  return $rc
}

stepsh() { # stepsh <名字> <shell 片段>
  name="$1"; snippet="$2"
  printf '\n===== %s =====\n' "$name" >>"$LOG"
  sh -c "$snippet" >>"$LOG" 2>&1
  rc=$?
  line=$(printf 'EXIT %-18s = %s' "$name" "$rc")
  printf '%s\n' "$line" >>"$LOG"
  printf '%s\n' "$line"
  return $rc
}

say "===== dsh sync-build-verify ====="
say "REPO  = $REPO"
say "USER  = $(id -un)@$(hostname)   $(date)"
say "HEAD  = $(git log -1 --format='%h %s')"
say "LOG   = $LOG"
say "--- swap / 内存（1.5 是共享生产机，先看这眼）---"
swapinfo -h 2>/dev/null | head -3 || true

DIRTY=$(git status --porcelain)
if [ -n "$DIRTY" ]; then
  say "!! 工作区不干净 —— 构建结果可能不可信:"
  printf '%s\n' "$DIRTY" | head -20
fi

step "pnpm-install" pnpm install || { say "RESULT: FAILED(install)"; exit 1; }
step "clean" pnpm run clean || { say "RESULT: FAILED(clean)"; exit 1; }
step "native-system" pnpm run build:native-system || { say "RESULT: FAILED(native-system)"; exit 1; }

if ! step "build-lib#1" pnpm run build:lib; then
  say "!! build:lib 第 1 次失败 —— 1.5 上多为 post-clean tsc OOM(exit 137)，重跑一次走增量续编"
  swapinfo -h 2>/dev/null | head -3 || true
  dmesg 2>/dev/null | grep 'was killed' | tail -3 || true
  step "build-lib#2" pnpm run build:lib || { say "RESULT: FAILED(build:lib)"; exit 1; }
fi

step "build-web" pnpm run build:web || { say "RESULT: FAILED(build:web)"; exit 1; }

say "--- 自动验证 ---"
stepsh "native-addon" 'find native/system/packages -maxdepth 3 -name system.node'
stepsh "flock-lib" 'ls -l native/system/packages/entry/lib/flock.js'
step "native-tests" pnpm --dir native/system test
stepsh "verify-sandbox" 'node freebsd/verify-sandbox.mjs'
step "translation-pairing" pnpm run verify-translation-pairing

say "===== SUMMARY ====="
grep -E '^EXIT |^RESULT:|^PASS=|^FAIL=|^clean: removed' "$LOG" 2>/dev/null || true
say "完整日志: $LOG"
say "RESULT: OK —— 别忘了重启服务并做冒烟（401/303、SANDBOX_UNAVAILABLE=0、发一条消息跑通一轮）"
