#!/bin/sh
# Push the FreeBSD fork (master + the latest sync base tag) to the three remotes.
# github -> SSH key; gitea -> GITEA_TOKEN; gitcode(origin) -> GITCODE_TOKEN.
set -a
. /home/workbuddy/github/deepseek-harness/.env
set +a
cd /home/workbuddy/github/deepseek-harness
HOOKS="core.hooksPath=/tmp/nohooks"

# 最新同步基线 tag（形如 fork-after-upstream-v0.1.5-rc.2）
# master 推了不代表 tag 推了 —— gitcode 曾漏掉 v0.1.5-rc.2，必须单独推。
BASE_TAG=$(git tag -l 'fork-after-upstream-*' --sort=-creatordate | head -1)
if [ -n "$BASE_TAG" ]; then echo "BASE_TAG=$BASE_TAG"; else echo "BASE_TAG=(none)"; fi

echo "=== push github (ssh) ==="
GIT_SSH_COMMAND="ssh -i /home/workbuddy/.ssh/id_ed25519_github -o StrictHostKeyChecking=no" \
  git -c "$HOOKS" push github master > /tmp/push_github.log 2>&1
echo "GITHUB_PUSH_EXIT=$?"
tail -8 /tmp/push_github.log

echo "=== push gitea (token) ==="
git -c "$HOOKS" \
  -c "url.http://${GITEA_TOKEN}:${GITEA_TOKEN}@192.168.1.5:3000/.insteadOf=http://192.168.1.5:3000/" \
  push gitea master > /tmp/push_gitea.log 2>&1
echo "GITEA_PUSH_EXIT=$?"
tail -8 /tmp/push_gitea.log

echo "=== push gitcode (origin, token) ==="
git -c "$HOOKS" \
  -c "url.https://oauth2:${GITCODE_TOKEN}@gitcode.com/.insteadOf=https://gitcode.com/" \
  push origin master > /tmp/push_gitcode.log 2>&1
echo "GITCODE_PUSH_EXIT=$?"
tail -8 /tmp/push_gitcode.log

if [ -n "$BASE_TAG" ]; then
  echo "=== push base tag -> github ==="
  GIT_SSH_COMMAND="ssh -i /home/workbuddy/.ssh/id_ed25519_github -o StrictHostKeyChecking=no" \
    git -c "$HOOKS" push github "$BASE_TAG" >> /tmp/push_github.log 2>&1
  echo "GITHUB_TAG_EXIT=$?"
  tail -3 /tmp/push_github.log

  echo "=== push base tag -> gitea ==="
  git -c "$HOOKS" \
    -c "url.http://${GITEA_TOKEN}:${GITEA_TOKEN}@192.168.1.5:3000/.insteadOf=http://192.168.1.5:3000/" \
    push gitea "$BASE_TAG" >> /tmp/push_gitea.log 2>&1
  echo "GITEA_TAG_EXIT=$?"
  tail -3 /tmp/push_gitea.log

  echo "=== push base tag -> gitcode ==="
  git -c "$HOOKS" \
    -c "url.https://oauth2:${GITCODE_TOKEN}@gitcode.com/.insteadOf=https://gitcode.com/" \
    push origin "$BASE_TAG" >> /tmp/push_gitcode.log 2>&1
  echo "GITCODE_TAG_EXIT=$?"
  tail -3 /tmp/push_gitcode.log
fi
