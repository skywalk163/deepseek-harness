#!/bin/sh
# ---------------------------------------------------------------------------
# dsh FreeBSD fork —— 分阶段构建（失败时能指名道姓说是哪一步）
#
# 为什么需要它：`sync-build-verify.sh` 只用 `pnpm run build:lib` 一个整体，
# 失败时你只知道「build:lib 挂了」，分不清是：
#   * `tsc -b` 类型错误（→ 改代码，与内存无关）     还是
#   * `tsdown` 打包失败（→ 常见于陈旧 lib/，先 clean）
#   * 真 OOM（→ /var/log/messages 里有本次时段的时间戳）
# 本脚本把 build:lib 拆成 tsc / tsdown 四步，每步前打印内存快照，逐步 `EXIT <步> = <rc>`。
#
# 用法:
#   sh freebsd/stage-build.sh [repo_root]
#
# ssh 通道下必须后台跑：
#   nohup sh freebsd/stage-build.sh > /tmp/stage-build.out 2>&1 </dev/null &
#   tail -f /tmp/stage-build.out
#
# 退出码: 0 = 全绿 / 1 = 构建失败 / 2 = 用法或环境错误
# ---------------------------------------------------------------------------
set -u

REPO="${1:-${DSH_REPO:-}}"
if [ -z "$REPO" ]; then
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  REPO=$(dirname "$SCRIPT_DIR")
fi
[ -d "$REPO/.git" ] || { echo "FATAL: 找不到仓库根: $REPO" >&2; exit 2; }
cd "$REPO" || exit 2

export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/local/sbin:$PATH"
export DSH_JAIL_RUN_BIN="${DSH_JAIL_RUN_BIN:-/var/dsh-jail-run}"

LOG="${DSH_STAGE_LOG:-/tmp/dsh-stage-build.log}"
: > "$LOG" 2>/dev/null || LOG="/tmp/dsh-stage-build.$$.log"

say() { printf '%s\n' "$*"; }

mem() {
  say "--- mem before $1 ---"
  swapinfo -h 2>/dev/null | tail -1
  say "$(sysctl -n vm.stats.vm.v_free_count) free pages"
}

stage() { # stage <名字> <命令...>
  name="$1"; shift
  mem "$name"
  printf '\n===== %s =====\n' "$name" >>"$LOG"
  printf '$ %s\n' "$*" >>"$LOG"
  "$@" >>"$LOG" 2>&1
  rc=$?
  printf 'EXIT %-16s = %s\n' "$name" "$rc" | tee -a "$LOG"
  return $rc
}

# 与 package.json 的 build:lib:host / build:lib:client 逐字对应，只是拆开跑。
# 用 node_modules/.bin/tsdown 直连，避免 npx 在无网机器上尝试联网。
TSC="node --max-old-space-size=3072 ./node_modules/typescript/bin/tsc"
TSDOWN="./node_modules/.bin/tsdown"

say "===== staged dsh build ====="
say "REPO = $REPO"
say "HEAD = $(git log -1 --format='%h %s')"
say "LOG  = $LOG"
say "system rg: $(command -v rg 2>/dev/null || echo '(缺)')"

stage tsc-host      $TSC -b tsconfig.host.json                  || { say "RESULT: FAILED(tsc-host —— 类型错误，看 $LOG 里的 error TS)"; exit 1; }
stage tsdown-host   $TSDOWN --env.DSH_BUILD_FACE host           || { say "RESULT: FAILED(tsdown-host —— 多为陈旧 lib/，先 pnpm run clean)"; exit 1; }
stage tsc-client    $TSC -b tsconfig.client.json                || { say "RESULT: FAILED(tsc-client)"; exit 1; }
stage tsdown-client $TSDOWN --env.DSH_BUILD_FACE client         || { say "RESULT: FAILED(tsdown-client)"; exit 1; }
stage build-web     pnpm --filter @deepseek-ai/dsh-web-frontend run build || { say "RESULT: FAILED(build-web)"; exit 1; }

say "===== SUMMARY ====="
grep -E '^EXIT |^RESULT:' "$LOG" 2>/dev/null || true
say "完整日志: $LOG"
say "RESULT: OK"
