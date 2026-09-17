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
#   * flock 行为测试的 C 预言机同样每台机器各自编译（native/system/test/bin/ 被 gitignore），
#     上游没有任何自动化会调用 `build:test-oracle` —— 本脚本显式跑它
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

DIRTY=$(git status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
  say "!! 工作区有未提交改动 —— 构建结果可能不可信:"
  printf '%s\n' "$DIRTY" | head -20
else
  say "工作区干净（仅跟踪文件；dsh_web.log / dsh_web.pid 等运行时文件不算）"
fi

step "pnpm-install" pnpm install || { say "RESULT: FAILED(install)"; exit 1; }
step "clean" pnpm run clean || { say "RESULT: FAILED(clean)"; exit 1; }
step "native-system" pnpm run build:native-system || { say "RESULT: FAILED(native-system)"; exit 1; }
# flock 行为测试依赖一个独立编译的 POSIX C 预言机
# (`native/system/test/bin/flock-oracle`，被 .gitignore 忽略 → 每台机器各自编译)。
# 上游只提供 `build:test-oracle` 脚本，**没有任何东西自动调用它**；忘了编译就会让
# 4 个 C 互操作用例以 ENOENT 失败（2026-09-17 在 0.88 上踩到，1.5 只是碰巧手工编过）。
step "test-oracle" pnpm --dir native/system build:test-oracle || { say "RESULT: FAILED(test-oracle)"; exit 1; }

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

# 定向 vitest（~11s）。本脚本原先完全不跑 vitest，于是「fork 故意改了行为 ↔ 上游测试
# 假设没改」这类冲突会一直潜伏：构建全绿，`pnpm test` 却早就坏了。2026-09-17 同步
# 0.1.6-alpha.1 时一次跑出 8 个必红（见技能 §7 表）。只跑 fork 动过行为的两个包。
step "vitest-scoped" pnpm exec vitest run packages/fs/tool-fs-search packages/sandbox/sandbox-local

say "===== SUMMARY ====="
grep -E '^EXIT |^RESULT:|^PASS=|^FAIL=|^clean: removed' "$LOG" 2>/dev/null || true
say "完整日志: $LOG"
say "RESULT: OK —— 别忘了重启服务并做冒烟（401/303、SANDBOX_UNAVAILABLE=0、发一条消息跑通一轮）"
say "           上面 SUMMARY 里的 EXIT 也要全 0：native-tests / verify-sandbox(10/10) / translation-pairing / vitest-scoped"
