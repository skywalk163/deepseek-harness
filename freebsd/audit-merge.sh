#!/bin/sh
# ---------------------------------------------------------------------------
# dsh FreeBSD fork —— 上游合并「fork 改动幸存审计」
#
# 为什么需要它：大跨度合并常常只有几个文件报冲突，但我们的 FreeBSD 改动散落在
# 十几处，其中多数位于上游也改过的文件里。git 自动合并会把文件合并成功，
# 却不保证我们那几行还在（上游重构同一函数时最容易被静默吃掉）。
#
# 用法:
#   sh freebsd/audit-merge.sh dsh-v0.1.6-alpha.1
#
# 行为：做一次 `git merge --no-commit --no-ff <tag>` 预演 -> 逐项断言 -> `git merge --abort`。
# 不留下任何改动。退出码: 0 = 全部 [OK] / 1 = 有 [LOST] / 2 = 用法或环境错误。
#
# 注意：[LOST] 出现在「本身就是冲突文件」的项上时，是索引里的中间态（带冲突标记），
# 不是真的丢了 —— 单独看那处冲突即可。脚本会在末尾提示这一点。
# ---------------------------------------------------------------------------
set -u

TAG="${1:-}"
REPO="${DSH_REPO:-}"
if [ -z "$REPO" ]; then
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  REPO=$(dirname "$SCRIPT_DIR")
fi
[ -n "$TAG" ] || { echo "用法: sh $0 <upstream-tag>   （例: sh $0 dsh-v0.1.6-alpha.1）" >&2; exit 2; }
cd "$REPO" || exit 2
git rev-parse --verify "$TAG^{commit}" >/dev/null 2>&1 || { echo "FATAL: 找不到 tag $TAG（先 git fetch upstream --tags）" >&2; exit 2; }

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "FATAL: 工作区有未提交改动，先处理干净再审计" >&2
  exit 2
fi

if git merge --no-commit --no-ff "$TAG" >/tmp/audit-merge.log 2>&1; then
  echo "(合并无冲突)"
else
  echo "(合并有冲突，正常；继续审计已自动合并的部分)"
fi
# 预演完成，无论后续如何都要 abort
trap 'git merge --abort >/dev/null 2>&1' EXIT INT TERM

echo
echo "===== 冲突文件与类型 ====="
git status --short | grep -E '^(UU|DU|UD|AA|AU|UA) ' || echo "(无)"
echo "冲突数=$(git status --short | grep -cE '^(UU|DU|UD|AA|AU|UA) ')"
echo
echo "===== Fork 关键改动幸存审计（合并索引里的结果）====="

LOST=0
chk() { # chk <标题> <最少匹配数> <shell 片段>
  title="$1"; min="$2"; snippet="$3"
  n=$(eval "$snippet" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -ge "$min" ]; then
    printf '[OK]   %-30s (%s)\n' "$title" "$n"
  else
    printf '[LOST] %-30s (%s < %s)\n' "$title" "$n" "$min"
    LOST=$((LOST + 1))
  fi
}

chk "pnpm supportedArchitectures" 1 "git show :pnpm-workspace.yaml | grep supportedArchitectures"
chk "  os 含 freebsd"             1 "git show :pnpm-workspace.yaml | grep freebsd"
chk "  libc glibc/musl"           1 "git show :pnpm-workspace.yaml | grep glibc"
chk "  shamefullyHoist"           1 "git show :pnpm-workspace.yaml | grep shamefullyHoist"
chk "sharp packageExtensions"     1 "git show :pnpm-workspace.yaml | grep sharp"
chk "package.json dsh:freebsd"    1 "git show :package.json | grep dsh:freebsd"
chk "package.json 3072 heap cap"  1 "git show :package.json | grep max-old-space-size=3072"
chk ".npmrc registry"             1 "git show :.npmrc | grep registry"
chk ".npmrc disturl"              1 "git show :.npmrc | grep disturl"
chk "terminal-bash freebsd"       1 "git show :packages/terminal/terminal-bash/src/config.ts | grep -i freebsd"
chk "process-inspector FreeBSD"   1 "git show :packages/subprocess/subprocess-local/src/process-inspector.ts | grep -i freebsd"
chk "search-core rg 回退"         1 "git show :packages/fs/tool-fs-search/src/search-core.ts | grep DSH_RIPGREP_PATH"
chk "sandbox freebsd hint"        1 "git show :packages/sandbox/sandbox/src/index.ts | grep -i freebsd"
chk "gen-* LF 归一化"             1 "git show :scripts/gen-config-catalog.ts | grep 'replace('"

echo
echo "----- 参考信息（不断言）-----"
printf 'knip.json:            '; git show :knip.json >/dev/null 2>&1 && echo "仍在" || echo "上游已删（接受）"
printf 'web crypto polyfill:  '; git show :apps/web/src/polyfill-crypto.ts >/dev/null 2>&1 && echo "我们的文件仍在" || echo "我们的文件已被上游取代"
printf 'main.ts 引用 polyfill: '; git show :apps/web/src/main.ts 2>/dev/null | grep -c -i polyfill
printf 'node-pty 声明:        '; grep -rn '"node-pty"' --include=package.json packages/ 2>/dev/null | head -1
printf 'patches:              '; ls patches/ 2>/dev/null | grep -i node-pty | tr '\n' ' '; echo
echo
echo "CI 关闭开关（合并后应仍在）:"
grep -rn "if: false" .github/workflows/ .gitea/workflows/ 2>/dev/null | sed 's/^/  /' || echo "  (无)"

echo
if [ "$LOST" -eq 0 ]; then
  echo "RESULT: 全部 [OK]"
else
  echo "RESULT: 有 $LOST 项 [LOST] —— 若该项所在文件本身就在上面的冲突清单里，"
  echo "        那是索引中的冲突中间态（不是真丢了），单独解那处冲突即可；"
  echo "        否则说明上游重构吃掉了我们的移植，按 runbook §4 表重新移植。"
fi
exit $([ "$LOST" -eq 0 ] && echo 0 || echo 1)
