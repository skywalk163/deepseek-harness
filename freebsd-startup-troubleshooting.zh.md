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

---

## [P4] 读一张图导致整个 web 服务退出（`fatal load failure: ErrnoError ... errno: 8`）

本机反复出现：会话里调用 `read_image`（或粘贴图片）后，工具报
`Error: sharp.libvipsVersion is not a function`，几秒后 `dsh_web.log` 出现
`dsh: fatal load failure: ErrnoError { name: 'ErrnoError', errno: 8 }`，服务退出、必须重启。

### 根因（两个缺陷，一个症状）

1. **FreeBSD 上的 sharp 是 WebAssembly 构建。** sharp 没有 `freebsd-x64` 原生二进制，实际解析到
   `@img/sharp-freebsd-wasm32` → `@img/sharp-wasm32`。它的 Emscripten 运行时会在**模块求值阶段**
   用 `fstatSync(0|1|2)` 建立 `/dev/stdin`、`/dev/stdout`、`/dev/stderr` 三条流。

2. **“存在但无法 fstat”的标准描述符会打断这次启动。** 这种描述符在 `fstat(1)` 里显示为 `bad`
   （**真正关闭**的描述符根本不会列出这一行）。此时 `fstatSync` 抛 `EBADF`，而运行时是把它当作
   **自身异步启动产生的 unhandled rejection** 报告出来，而不是抛出可捕获的加载错误，于是
   `require('sharp')` “成功”了，但拿到的是半初始化绑定：
   - 第一次光栅操作报 `sharp.libvipsVersion is not a function`；
   - `installFailLoud` 把这条游离的 `ErrnoError` 当作致命错误并退出进程。

   FreeBSD 的 `revoke(2)` 正好制造这种描述符状态——控制会话结束时它会让终端上的描述符失效，
   而 sshd 对服务就是这么做的。本机存活的服务进程在 `fstat` 里确实显示 `0 - - bad -`，
   而它当时仍在监听 `:3080`。

### 复现（确定性）

在首次加载 sharp 之前关闭三个标准描述符，可精确复现线上的成对症状：

```
closed 0:EBADF 1:EBADF 2:EBADF
RAW THREW sharp.libvipsVersion is not a function
UNHANDLED ErrnoError errno=8
```

对进程自身的 pty 执行 `revoke(2)` 会得到同样的 `0:EBADF 1:EBADF 2:EBADF` 首行，即同一故障。
注意：`bad` 描述符**无法靠重试 `require('sharp')` 修复**——Emscripten 模块已以损坏状态初始化并被缓存，
重试仍然失败。

### 修复

- `packages/attachment/attachment-local/src/sharp.ts`：新增 `ensureStandardStreams()`，对 0/1/2 做 `fstat`，
  把不可用的描述符重绑到 `/dev/null`（先 `closeSync` 再 `openSync`，利用“最小空闲描述符号”规则占回同一位）。
  `requireSharp()` 在加载前调用它；若某个描述符无法恢复，则直接拒绝加载，而不是触发那条致命 rejection。
  `LocalAttachmentStore` 构造函数也在挂载时执行同一修复，使修复发生在启动期而非首次读图时。
- `freebsd/dsh_web.rcd` 与 `freebsd/dsh-web-restart.sh`：启动时显式 `</dev/null`，避免被托管进程继承
  一个失效的描述符 0。
- 在同样的损坏状态下验证：`repaired=[0,1,2]` → 读图流水线正常返回图像字节。
- 回归测试：`packages/attachment/attachment-local/tests/standard-streams.spec.ts`。

### 修复（排查中发现的第二个、独立缺陷）

`freebsd/dsh_web.rcd` 和 `freebsd/dsh-web-restart.sh` 用 `pgrep -f` / `pkill -f` 判断服务。
**FreeBSD 的 `pgrep`/`pkill` 默认会排除自身及所有直接祖先进程（除非加 `-a`）。** 这两个脚本通常在
dsh 会话内部执行，此时 harness 进程正是祖先，于是 `sh freebsd/dsh-web-restart.sh status` 会把健康的服务
报成 `NOT running`，`stop`/`restart` 也可能“报成功”却什么都没停。现在两个脚本都加了 `-a`
（仍保留 `[d]sh` 括号写法，避免匹配到自己的 argv），且 `stop` 在调用方是服务后代时会先给出提示。

### 经验

- FreeBSD 上 `fstat(1)` 的 `bad` 表示“描述符存在但不可 stat”，不是“已关闭”。
- 若某个依赖把**异步**启动失败以 unhandled rejection 形式抛出，即使失败调用与 rejection 位置无关，
  也会让装有 fail-loud 处理器的进程直接退出。
- 任何可能从被查找进程内部执行的脚本，FreeBSD 上的 `pgrep`/`pkill` 都要加 `-a`。
