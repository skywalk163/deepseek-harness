# deepseek-harness — current-version startup troubleshooting log (1.5 / 192.168.1.5)

- Date: 2026-08-18
- Host: 192.168.1.5 (FreeBSD, user `workbuddy`)
- Repo: `/home/workbuddy/github/deepseek-harness`
- Goal: start the **current** (master) deepseek-harness web, record every error encountered and fix them one by one

## Environment snapshot (before build)
- git HEAD = `8d0ac97fe6` (= `origin/master`, already current; the last 3 commits are CI workflow changes only, no runtime impact)
- node v24.12.0 / pnpm 11.7.0 (`~/.local/bin/pnpm`, persisted)
- Before stopping the old instance: web was healthy on 127.0.0.1:3080 (HTTP 200)
- 2 pytest CI jobs from other repos were running (~100 MB each); free memory ~3.6 GB (`v_free_count` 918998 × 4 KB)
- Untracked files: `dsh_web.log`, `freebsd/push.sh`, `validate_build.sh` (local work artifacts, not committed)

## Problem timeline

### [P1] `pgrep -f` self-match made the old web process look alive
- Symptom: after `sh freebsd/dsh-web-restart.sh stop`, `pgrep -af "dsh:freebsd"` still listed 3 PIDs (95904/21398/97080) and printed PIDs only, no command lines.
- Root cause: the remote command string itself contains `dsh:freebsd`, so the remote shell (`bash -c '...'`) executing it matches the pattern → pgrep matched **its own shell** (and children), not a leftover web process.
- Fix: use the bracket trick `pgrep -af "[d]sh:freebsd"` plus `sockstat -l -p 3080` plus `curl` — no match, no listener on 3080, HTTP 000 → the old instance was fully stopped.
- Lesson: on FreeBSD remote commands, pgrep/pkill patterns must use the `[x]` bracket trick to avoid self-match (already recorded in the skill; hit again).

### [P2] `dsh_ssh.py` argument order: timeout was taken as cwd
- Symptom: `dsh_ssh.py cmd '<cmd>' 60` failed with `cd: 60: No such file or directory`; the `&&` chain broke and the first half of the command never ran.
- Root cause: `dsh_ssh.py cmd` takes `cmd <command> [cwd] [timeout]` — the 3rd positional is **cwd**, not timeout; passing `60` was treated as the working directory.
- Fix: use `-` as the cwd placeholder: `dsh_ssh.py cmd '<cmd>' - 60`.
- Lesson: this script's `cmd` subcommand needs an explicit `-` cwd placeholder before a timeout can be given.

### [P3] paramiko PipeTimeout while running `dsh-web-restart.sh start`
- Symptom: `dsh_ssh.py cmd 'sh freebsd/dsh-web-restart.sh start ...'` threw `paramiko.buffered_pipe.PipeTimeout` after ~60 s, exit 1.
- Root cause: the `daemon`-launched web process inherits the ssh channel's stdout/stderr (or the start script waits for initialization), so the channel never closes after the command "ends" → `stdout.read()` blocks until the timeout. This is a known friction between daemon-style starts and interactive ssh pipe reads (the 0.88 box showed a similar "swallowed output" quirk with rc.d/daemon).
- Fix: **do not wait for that command to return**; after the timeout, open a fresh ssh channel and verify independently (`sockstat -l -p 3080` / `curl` / `pgrep -af "[d]sh:freebsd"`) — the web server was actually up.
- Lesson: for daemon/service start commands, either use `dsh_ssh.py bg` (nohup background + separate log) or accept the timeout and verify on a new channel; never treat the timeout as a start failure.

## Build & startup results (all passed)
- Build: 17:55:27 → 18:00:31 (incremental, 5 min), `BUILD_ALL_OK`; the only output was a vite chunk >500 kB warning (not an error)
- web: HTTP 200; `sockstat` shows `workbuddy node 12164 tcp4 127.0.0.1:3080`; `dsh_web.log` tail normal
- Log error scan: `grep -cE "ERROR|SANDBOX_UNAVAILABLE|ENOENT|Traceback|FATAL"` = **0**
- Process env: `DSH_JAIL_RUN_BIN=/var/dsh-jail-run` (jail sandbox active); no `danger-full-access` (restricted mode)
- Sandbox smoke: `DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs` = **10/10 PASS** (confine / RO write-denied / workspace-write / network isolation all pass)

## Verification checklist
- [x] `build:lib:host` passed
- [x] `build:lib:client` passed
- [x] `build:web` passed (21.35 s)
- [x] `BUILD_ALL_OK` present
- [x] web restarted: HTTP 200
- [x] `dsh_web.log` no ERROR/exceptions (0 hits)
- [x] port 3080 listening
- [x] sandbox smoke (verify-sandbox 10/10, SANDBOX_UNAVAILABLE=0)

## Conclusion
Current master (`8d0ac97fe6`) builds (incremental) and starts on 1.5 with **zero errors**. This run recorded 3 non-blocking issues (pgrep self-match, `dsh_ssh.py` argument order, daemon-start timeout), all tooling/command-usage problems, none in repo code.
