#!/bin/sh
# ---------------------------------------------------------------------------
# dsh FreeBSD fork —— 把 master + 最新同步基线 tag 推到三个远端
#
# 原版写死了 1.5 机器的路径（/home/workbuddy/...、它的 .env、它的 github SSH key），
# 换到 0.88 / fb98 上只能手工敲 git 命令。本版把它参数化：**仓库根从脚本位置推导**，
# 凭据/远端/SSH key 全部可用环境变量覆盖，远端名不存在时自动回退到 URL 形态。
#
# 用法:
#   sh freebsd/push.sh                  # 推 master + 最新基线 tag 到三个远端
#   sh freebsd/push.sh --dry-run        # 只打印将要执行什么，不推
#   sh freebsd/push.sh --only gitea     # 只推一个（可重复：--only github --only gitcode）
#   sh freebsd/push.sh --no-tag         # 只推 master
#   sh freebsd/push.sh --verify-only    # 只做三远端 sha 复核，不推
#
# 环境变量（都可选，给默认值；带 * 的没有默认就必须显式给）:
#   DSH_ENV               凭据文件。默认按序找：$REPO_ROOT/.env、$HOME/dswork/.env、
#                         /home/workbuddy/github/deepseek-harness/.env
#   GITCODE_TOKEN*        gitcode 令牌（origin 用）
#   GITEA_TOKEN*          gitea 令牌；也可只给 `gitea=` URL（见下）
#   GITEA_USER            gitea 用户名；默认从 `gitea=` URL 的 userinfo 取
#   DSH_GITEA_URL         gitea 基址，如 http://192.168.1.5:3000
#                         默认从 env 里 `gitea=http://user:token@host:port/owner/repo.git` 解析
#   DSH_GITEA_REPO_PATH   gitea 仓库路径，默认 /skywalk/deepseek-harness.git
#   DSH_GITHUB_URL        github 仓库 URL，默认 git@github.com:skywalk163/deepseek-harness.git
#   DSH_GITHUB_SSH_KEY    github SSH 私钥；默认 $HOME/.ssh/id_ed25519_github，再退 $HOME/.ssh/id_ed25519
#   DSH_PUSH_HOOKS=1      保留本地 git hooks（默认 0 = 走 core.hooksPath=/tmp/nohooks 跳过，
#                         与原版行为一致；hooks 开着会跑 lefthook typecheck，慢但更安全）
#   DSH_PUSH_TAG          指定要推的基线 tag；默认取 creatordate 最新的 fork-after-upstream-*
#   DSH_PUSH_LOG_DIR      push 日志目录，默认 /tmp
#
# 退出码: 0 = 所有**尝试过的**远端都成功（被跳过的远端不算失败）
#         1 = 至少一个远端推送或复核失败
#         2 = 用法/环境错误
# ---------------------------------------------------------------------------
set -u
# 凭据缺失时立刻失败：本脚本常在非交互通道（ssh 后台 / CI）里跑，
# git 的交互式 Username 提示会让整个推送静默挂死（2026-11-23 踩过）。
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
DRY_RUN=0
PUSH_TAG=1
VERIFY_ONLY=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1 ;;
    --no-tag)      PUSH_TAG=0 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --only)        shift; [ $# -gt 0 ] || { echo "FATAL: --only 需要参数" >&2; exit 2; }
                   ONLY="$ONLY $1" ;;
    -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "FATAL: 未知参数 $1（--help 看用法）" >&2; exit 2 ;;
  esac
  shift
done

want() {  # want <name>：没给 --only 就全要；给了就只挑点名的
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

[ -d "$REPO_ROOT/.git" ] || { echo "FATAL: 找不到仓库根: $REPO_ROOT" >&2; exit 2; }
cd "$REPO_ROOT" || exit 2

LOG_DIR="${DSH_PUSH_LOG_DIR:-/tmp}"

# --- 凭据：只解析需要的键，不 source 整个 .env -----------------------------
# 为什么不用 `. .env`：本机（0.88）的 .env 里有 `15SSH_HOST=...` 这类非法标识符行，
# set -a 下会被 sh 当命令执行，刷一串 "command not found"（T-0358/0359 实测）。
# 逐键读取既没有副作用，也不会把无关的密钥导进环境。
ENV_FILE=""
if [ -n "${DSH_ENV:-}" ]; then
  ENV_FILE="$DSH_ENV"
else
  for c in "$REPO_ROOT/.env" "$HOME/dswork/.env" \
           /home/workbuddy/github/deepseek-harness/.env; do
    [ -f "$c" ] && { ENV_FILE="$c"; break; }
  done
fi

env_get() {  # env_get <KEY>：取 KEY=value 的值（去引号、去 CR）；不存在则输出空
  [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -1 \
    | tr -d '\r' | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//"
}

# 环境里没给的令牌，从 env 文件补齐（原版是 source 整个 .env；我们只取需要的键）。
# 显式环境变量优先，方便 CI/临时覆盖。
GITCODE_TOKEN="${GITCODE_TOKEN:-$(env_get GITCODE_TOKEN)}"
GITEA_TOKEN="${GITEA_TOKEN:-$(env_get GITEA_TOKEN)}"
GITHUB_TOKEN="${GITHUB_TOKEN:-$(env_get GITHUB_TOKEN)}"
export GITCODE_TOKEN GITEA_TOKEN GITHUB_TOKEN

say() { printf '%s\n' "$*"; }

# 把日志里的令牌抹掉再回显，别让密钥进终端 / CI 输出
redact() {
  sed -e "s#//[^@/]*@#//<redacted>@#g" \
      -e "s/${GITCODE_TOKEN:-__none__}/<redacted>/g" \
      -e "s/${GITEA_TOKEN:-__none__}/<redacted>/g"
}

# --- 推的目标：优先用同名 remote，没有就回退 URL ---------------------------
has_remote() { git remote | grep -qx "$1"; }

GITCODE_URL=""
if has_remote origin; then
  GITCODE_URL=$(git remote get-url origin)
else
  GITCODE_URL="https://gitcode.com/skywalk163/deepseek-harness.git"
fi

GITHUB_URL="${DSH_GITHUB_URL:-git@github.com:skywalk163/deepseek-harness.git}"

# gitea：可用 remote `gitea`；否则从 DSH_GITEA_URL + DSH_GITEA_REPO_PATH 拼，
# 或从 env 的 `gitea=http://user:token@host:port/...` 里解析出基址与 userinfo。
GITEA_BASE="${DSH_GITEA_URL:-}"
GITEA_REPO_PATH="${DSH_GITEA_REPO_PATH:-/skywalk/deepseek-harness.git}"
GITEA_USER_ENV="${GITEA_USER:-}"
GITEA_TOKEN_ENV="${GITEA_TOKEN:-}"
if [ -z "$GITEA_BASE" ]; then
  raw=$(env_get gitea)
  if [ -n "$raw" ]; then
    # http://user:token@host:port/path -> base=http://host:port, userinfo=user:token
    case "$raw" in
      *://*@*) base_no_auth=$(printf '%s' "$raw" | sed -E 's#(^[a-z]+://)[^@]*@#\1#')
               userinfo=$(printf '%s' "$raw" | sed -E 's#^[a-z]+://([^@]*)@.*#\1#')
               GITEA_BASE=$(printf '%s' "$base_no_auth" | sed -E 's#(^[a-z]+://[^/]+).*#\1#')
               [ -n "$GITEA_REPO_PATH" ] || GITEA_REPO_PATH=$(printf '%s' "$base_no_auth" | sed -E 's#^[a-z]+://[^/]+##')
               if [ -z "$GITEA_USER_ENV" ]; then
                 GITEA_USER_ENV=$(printf '%s' "$userinfo" | cut -d: -f1)
               fi
               if [ -z "$GITEA_TOKEN_ENV" ]; then
                 GITEA_TOKEN_ENV=$(printf '%s' "$userinfo" | cut -s -d: -f2-)
               fi ;;
    esac
  fi
fi

# 组装带凭据的推送 URL（只在内存里，回显前一律 redact）
# 兜底：.env 里写的是大写 `GITEA_URL`（不带 userinfo），早期版本只认小写 `gitea=`。
# 不给这条兜底时 gitea_push_url() 会退回「无凭据的 remote URL」，push 挂在 Username 提示上。
if [ -z "$GITEA_BASE" ]; then
  GITEA_BASE=$(env_get GITEA_URL)
fi
if [ -z "$GITEA_USER_ENV" ] && [ -n "$GITEA_BASE" ]; then
  GITEA_USER_ENV=$(env_get GITEA_ADMIN_USER)
fi

gitcode_push_url() {
  if [ -n "${GITCODE_TOKEN:-}" ]; then
    case "$GITCODE_URL" in
      https://*) printf '%s' "$GITCODE_URL" | sed "s#^https://#https://oauth2:${GITCODE_TOKEN}@#" ;;
      *) printf '%s' "$GITCODE_URL" ;;
    esac
  else
    printf '%s' "$GITCODE_URL"
  fi
}

gitea_push_url() {
  if [ -n "$GITEA_BASE" ] && [ -n "$GITEA_TOKEN_ENV" ]; then
    printf '%s://%s:%s@%s%s' \
      "$(printf '%s' "$GITEA_BASE" | sed -E 's#^(https?)://.*#\1#')" \
      "${GITEA_USER_ENV:-oauth2}" "$GITEA_TOKEN_ENV" \
      "$(printf '%s' "$GITEA_BASE" | sed -E 's#^https?://##')" "$GITEA_REPO_PATH"
  elif has_remote gitea; then
    git remote get-url gitea
  fi
}

# GitHub 的 SSH 身份：只有找到真实的 key 文件才加 -i，否则交给 ssh 默认查找
GITHUB_SSH=""
for k in "${DSH_GITHUB_SSH_KEY:-}" "$HOME/.ssh/id_ed25519_github" "$HOME/.ssh/id_ed25519"; do
  if [ -n "$k" ] && [ -r "$k" ]; then
    GITHUB_SSH="ssh -i $k -o StrictHostKeyChecking=no"
    break
  fi
done

HOOKS_ARG=""
if [ "${DSH_PUSH_HOOKS:-0}" != "1" ]; then HOOKS_ARG="core.hooksPath=/tmp/nohooks"; fi

# --- 基线 tag ---------------------------------------------------------------
BASE_TAG="${DSH_PUSH_TAG:-$(git tag -l 'fork-after-upstream-*' --sort=-creatordate | head -1)}"
if [ -n "$BASE_TAG" ]; then
  say "BASE_TAG = $BASE_TAG  -> $(git rev-parse --short "$BASE_TAG^{commit}" 2>/dev/null || echo '?')"
  # 基线 tag 必须打在 merge 提交上（有 ^2），否则下一轮同步的线性判定会假警报
  if ! git rev-parse --verify -q "$BASE_TAG^2" >/dev/null; then
    say "!! 警告：$BASE_TAG 不是双亲提交（没有 ^2），下轮 upstream-sync 的线性判定会报假红线"
  fi
else
  say "BASE_TAG = (none)"
fi

say "REPO_ROOT = $REPO_ROOT"
say "ENV_FILE  = ${ENV_FILE:-(未找到)}"
say "LOCAL     = $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
[ "$DRY_RUN" = "1" ] && say "（dry-run：只打印，不推送）"

FAILED=0
ATTEMPTED=""

# --- 单个远端：先推 master，再推 tag ---------------------------------------
push_one() {  # push_one <名字> <url> <ssh-cmd|"">
  name="$1"; url="$2"; sshcmd="$3"
  log="$LOG_DIR/push_$name.log"
  ATTEMPTED="$ATTEMPTED $name"

  if [ -z "$url" ]; then
    say "--- $name: SKIP（没找到远端，也没给 URL/凭据）"
    return 0
  fi

  say "=== push $name: master ==="
  if [ "$DRY_RUN" = "1" ]; then
    say "    would run: git push $(printf '%s' "$url" | sed -E 's#//[^@/]*@#//<redacted>@#g') master"
  else
    # shellcheck disable=SC2086
    if GIT_SSH_COMMAND="$sshcmd" git ${HOOKS_ARG:+-c "$HOOKS_ARG"} \
         push "$url" master >"$log" 2>&1; then
      say "    ${name} master: OK"
      redact <"$log" | tail -3 | sed 's/^/    /'
    else
      say "    ${name} master: FAILED（日志 $log）"
      redact <"$log" | tail -6 | sed 's/^/    /'
      FAILED=1
      return 1
    fi
  fi

  if [ "$PUSH_TAG" = "1" ] && [ -n "$BASE_TAG" ]; then
    say "--- push $name: tag $BASE_TAG"
    if [ "$DRY_RUN" = "1" ]; then
      say "    would run: git push <url> $BASE_TAG"
    else
      # shellcheck disable=SC2086
      if GIT_SSH_COMMAND="$sshcmd" git ${HOOKS_ARG:+-c "$HOOKS_ARG"} \
           push "$url" "$BASE_TAG" >>"$log" 2>&1; then
        say "    ${name} tag: OK"
        redact <"$log" | tail -2 | sed 's/^/    /'
      else
        say "    ${name} tag: FAILED（日志 $log）"
        redact <"$log" | tail -6 | sed 's/^/    /'
        FAILED=1
        return 1
      fi
    fi
  fi
  return 0
}

if [ "$VERIFY_ONLY" = "0" ]; then
  want github && push_one github "$GITHUB_URL" "$GITHUB_SSH"
  want gitea  && push_one gitea  "$(gitea_push_url)" ""
  want gitcode && push_one gitcode "$(gitcode_push_url)" ""
fi

# --- 复核：三远端 master/tag 的 sha 必须与本地一致 --------------------------
say ""
say "===== 复核（ls-remote）====="
LOCAL_MASTER=$(git rev-parse master 2>/dev/null || git rev-parse HEAD)
LOCAL_TAG=$(git rev-parse "$BASE_TAG^{commit}" 2>/dev/null || echo "")
say "local master = $LOCAL_MASTER"
if [ "$PUSH_TAG" = "1" ] && [ -n "$LOCAL_TAG" ]; then
  say "local tag    = $LOCAL_TAG"
else
  say "local tag    = (--no-tag：不推也不校验 tag)"
fi

verify_one() {  # verify_one <名字> <url> <ssh-cmd|"">
  name="$1"; url="$2"; sshcmd="$3"
  [ -n "$url" ] || return 0
  refs="refs/heads/master"
  [ "$PUSH_TAG" = "1" ] && [ -n "$BASE_TAG" ] && refs="$refs refs/tags/$BASE_TAG"
  # shellcheck disable=SC2086
  out=$(GIT_SSH_COMMAND="$sshcmd" git ls-remote "$url" $refs 2>&1) || {
    say "  $name: ls-remote 失败"; redact <<EOF | tail -3 | sed 's/^/    /'
$out
EOF
    FAILED=1; return 1; }
  rmaster=$(printf '%s\n' "$out" | awk '$2=="refs/heads/master"{print $1}')
  rtag=$(printf '%s\n' "$out" | awk -v t="refs/tags/$BASE_TAG" '$2==t{print $1}')
  ok=1
  if [ "$rmaster" != "$LOCAL_MASTER" ]; then
    say "  $name master: MISMATCH  远端=${rmaster:-<none>}"; ok=0
  else
    say "  $name master: OK $rmaster"
  fi
  if [ "$PUSH_TAG" = "1" ] && [ -n "$BASE_TAG" ]; then
    if [ "$rtag" != "$LOCAL_TAG" ]; then
      say "  $name tag:    MISMATCH  远端=${rtag:-<none>}"; ok=0
    else
      say "  $name tag:    OK $rtag"
    fi
  fi
  [ "$ok" = "1" ] || FAILED=1
}

verify_one github "$GITHUB_URL" "$GITHUB_SSH"
verify_one gitea  "$(gitea_push_url)" ""
verify_one gitcode "$(gitcode_push_url)" ""

say ""
if [ "$FAILED" = "0" ]; then
  say "RESULT: OK"
else
  say "RESULT: FAILED —— 见上面 MISMATCH / FAILED 行与 $LOG_DIR/push_*.log"
fi
exit "$FAILED"
