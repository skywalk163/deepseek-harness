#!/bin/sh
# Push the FreeBSD jail sandbox work to the three remotes.
# github -> SSH key; gitea -> GITEA_TOKEN; gitcode(origin) -> GITCODE_TOKEN.
set -a
. /home/workbuddy/github/deepseek-harness/.env
set +a
cd /home/workbuddy/github/deepseek-harness
HOOKS="core.hooksPath=/tmp/nohooks"

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
