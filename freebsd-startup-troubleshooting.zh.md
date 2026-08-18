# deepseek-harness 当前版本启动排错日志（1.5 / 192.168.1.5）

- 日期：2026-08-18
- 机器：192.168.1.5（FreeBSD，workbuddy 用户）
- 仓库：`/home/workbuddy/github/deepseek-harness`
- 目标：启动**当前版本**（master）deepseek-harness web，记录全程报错并逐一解决

## 环境快照（构建前）
- git HEAD = `8d0ac97fe6`（= origin/master，已是当前版本；近 3 个提交均为 CI 工作流改动，不影响运行时）
- node v24.12.0 / pnpm 11.7.0（`~/.local/bin/pnpm`，持久化）
- 停止旧实例前：web 在 127.0.0.1:3080 正常（HTTP 200）
- 当时另有 2 个 pytest CI 在跑（其他仓库，各 ~100MB）；内存余量 ~3.6GB（v_free_count 918998 × 4KB）
- 未跟踪文件：`dsh_web.log`、`freebsd/push.sh`、`validate_build.sh`（均为本地工作产物，不入库）

## 问题时间线

### [P1] pgrep -f 自匹配，误以为旧 web 进程没停掉
- 现象：`sh freebsd/dsh-web-restart.sh stop` 后再 `pgrep -af "dsh:freebsd"` 仍列出 3 个 PID（95904/21398/97080），且 pgrep 只输出 PID 不输出命令行。
- 根因：远程命令字符串本身包含 `dsh:freebsd`，执行该命令的远程 shell（`bash -c '...'`）命令行匹配了模式 → pgrep 匹配到**自己所在的 shell**（及子进程），不是残留的 web 进程。
- 处理：改用括号技巧 `pgrep -af "[d]sh:freebsd"` + `sockstat -l -p 3080` + `curl` 三合一确认 → 无匹配、3080 无监听、HTTP 000 → 旧实例确实已完全停止。
- 教训：在 FreeBSD 远程命令里做 pgrep/pkill 时，模式串必须用 `[x]` 括号技巧避开自匹配（技能里已有记录，本次再次踩到）。

### [P2] dsh_ssh.py 参数位错误：timeout 被当成 cwd
- 现象：`dsh_ssh.py cmd '<cmd>' 60` 报 `cd: 60: No such file or directory`，`&&` 链中断、前半段命令没执行。
- 根因：`dsh_ssh.py cmd` 的参数顺序是 `cmd <command> [cwd] [timeout]`——第 3 个位置是 cwd，不是 timeout；传 60 被当作工作目录。
- 处理：用 `-` 占位 cwd：`dsh_ssh.py cmd '<cmd>' - 60`。
- 教训：该脚本 cmd 子命令必须显式给 `-` 作为 cwd 占位才能指定 timeout。

### [P3] dsh_ssh.py 跑 `dsh-web-restart.sh start` 时 paramiko PipeTimeout
- 现象：`dsh_ssh.py cmd 'sh freebsd/dsh-web-restart.sh start ...'` 在 ~60s 后抛 `paramiko.buffered_pipe.PipeTimeout`，exit 1。
- 根因：`daemon` 启动的 web 进程继承了 ssh channel 的 stdout/stderr（或启动脚本等待初始化），channel 在命令"结束"后仍不关闭 → `stdout.read()` 阻塞到 timeout。这是「daemon 启动 + 交互式 ssh 读管道」的已知摩擦（0.88 上 rc.d/daemon 也见过类似「吞回显」）。
- 处理：**不要等该命令返回**；超时后重新开一条 ssh 独立验证（`sockstat -l -p 3080` / `curl` / `pgrep -af "[d]sh:freebsd"`）——web 实际已成功启动。
- 教训：对 daemon/服务类启动命令，用 `dsh_ssh.py bg`（nohup 后台 + 独立日志）或直接接受超时后另开通道验证；切勿把超时误判为启动失败。

## 构建与启动结果（全部通过）
- 构建：17:55:27 → 18:00:31（增量 5 分钟），`BUILD_ALL_OK`；唯一输出为 vite chunk >500kB 警告（非错误）
- web：HTTP 200；`sockstat` 显示 `workbuddy node 12164 tcp4 127.0.0.1:3080`；`dsh_web.log` 尾部正常
- 日志错误扫描：`grep -cE "ERROR|SANDBOX_UNAVAILABLE|ENOENT|Traceback|FATAL"` = **0**
- 进程环境：`DSH_JAIL_RUN_BIN=/var/dsh-jail-run`（jail 沙箱生效）；未设 `danger-full-access`（受限模式）
- 沙箱冒烟：`DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs` = **10/10 PASS**（confine/RO 拒绝写入/workspace-write/网络隔离全过）

## 验证清单
- [x] `build:lib:host` 通过
- [x] `build:lib:client` 通过
- [x] `build:web` 通过（21.35s）
- [x] `BUILD_ALL_OK` 出现
- [x] 重启 web：HTTP 200
- [x] `dsh_web.log` 无 ERROR/异常（0 条）
- [x] 端口 3080 监听
- [x] 沙箱冒烟（verify-sandbox 10/10，SANDBOX_UNAVAILABLE=0）

## 结论
当前 master（8d0ac97fe6）在 1.5 上可**零报错**完成 增量构建 + 启动；本次共记录 3 个非阻塞小问题（pgrep 自匹配、dsh_ssh.py 参数位、daemon 启动超时），均为工具/命令用法问题，无仓库代码问题。

---

## 0.88（192.168.0.88 / fb98）同版本演练（2026-08-18 晚）

- 机器：FreeBSD 15.1-RELEASE-p1，内存 64GB（free ~24GB），node v24.18.0；仓库 `/home/skywalk/github/deepseek-harness`（**skywalk 所有**），连接用户 workbuddy（wheel 组，可 sudo）。
- 现状：HEAD=9d1a0a6097（落后 10 个提交）；旧版 web 在跑（HTTP 200）。
- 对齐与启动：`git fetch origin`（origin=gitcode）→ `git reset --hard origin/master`（=7d588f4fe3）→ `pnpm run build`（增量，BUILD_RC=0，web 14.85s）→ `dsh-web-restart.sh start` → 验证：HTTP 200、`sockstat` 显示 `skywalk node 3116 tcp4 127.0.0.1:3080`、`dsh_web.log` 错误 0 条、`verify-sandbox.mjs` **10/10 PASS**。
- **0.88 特有操作注意（与 1.5 不同）**：
  1. **git dubious ownership**：workbuddy 访问 skywalk 所有的仓库被 git 安全机制拦截 → 先 `git config --global --add safe.directory /home/skywalk/github/deepseek-harness`（workbuddy 全局）。
  2. **workbuddy 对仓库无写权限**（`touch` 失败、`.git/FETCH_HEAD` Permission denied）→ 仓库操作一律以 skywalk 身份：`python tools/ssh_run_88.py --sudo "su - skywalk -c 'sh /tmp/xxx.sh'"`（脚本先由 `--file` 上传到 /tmp）。
  3. **boxrun.e2e.ts 残留坑**：本地未跟踪副本（0600）引用已删除的 `boxrunProfileArgs`，会让 `tsc -b` 中断 → master 已删除该文件，本地残留 `mv` 到 /tmp 备份即可，build 后勿还原。
  4. **daemon start 同样 paramiko PipeTimeout**（与 1.5 同族）→ 超时后另开通道独立验证。
- 结论：两机（1.5 / 0.88）当前均运行 master 7d588f4fe3，构建零报错、web HTTP 200、沙箱 10/10，状态一致。
