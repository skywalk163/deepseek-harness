# DeepSeek Harness（dsh）FreeBSD jail 沙盒后端 — 部署与运维手册（新手可盲操）

> 适用对象：从没碰过这个仓库、但要在 FreeBSD 上把 jail 沙盒跑起来并会排错的人。
> 配套总手册：`FREEBSD.md` / `FREEBSD.zh.md`（§8.1 有本手册的交叉引用）。
> 本文所有命令均已在 **FreeBSD 14.3-RELEASE-p7 amd64** 上实跑验证；下文"已验证状态"一节给出可照抄复核的结果。

---

## 0. 这份手册讲什么 / 不讲什么

- **讲**：FreeBSD jail 沙盒后端（`freebsd/dsh-jail-run.c` 这个 setuid-root helper）的**编译、安装、配置、启动、验证、排错、安全、升级**。
- **不讲**：内核编译、改写 jail 底层机制、或对内核漏洞的对抗。本文只写 harness 侧后端的使用文档——你不需要重新编译内核，也不需要改 jail 源码（除非你要升级 helper，见第 8 章）。

读完这份手册，你应该能：
1. 在一台干净的 FreeBSD 13+/14.x 上把沙盒跑起来；
2. 用一条命令确认它确实在隔离（10/10、5/5）；
3. 出问题时按排错表定位到根因并修掉。

---

## 1. 概述与架构一分钟

dsh 在 FreeBSD 上没有内建沙盒后端（上游只认 Linux 的 bwrap/Landlock、macOS 的 Seatbelt、Windows 的 ACL 受限令牌）。本仓库补了一个**真正的 FreeBSD jail 后端**，由 setuid-root 的 `dsh-jail-run` helper 驱动。

一条 `code` / `mini` / `standard` 命令被下发时，harness 的本地沙盒 provider 会这样处理：

```
你的命令 argv
   │  confine()
   ▼
dsh-jail-run --workspace <宿主workspaceRoot> --mode <read-only|workspace-write> -- <你的命令>
   │
   ├─ 1. 校验 workspace：必须是绝对路径、realpath 解析无 ".."、且不能是 "/"
   ├─ 2. 在一个 root 所有的临时目录里建一个临时 jail（jailparam_set, persist=1）
   ├─ 3. 挂载（全部在子进程降权之前，仍以 root 做）：
   │      • 宿主系统目录（/bin /sbin /lib /etc /usr/bin ...）  —— 只读 nullfs
   │      • workspace（你指定的根目录）                        —— read-only 只读 / workspace-write 可读写
   │      • /dev —— 受限 devfs（ruleset 4，只给 jail 该有的设备）
   │      • /tmp —— 全新 tmpfs（随 jail 消亡，绝不落到宿主 /tmp）
   │      • /var/run/ld-elf.so.hints —— 只读 nullfs（让动态链接器能找到 /usr/local/lib 的库）
   ├─ 4. jail_attach 进 jail
   ├─ 5. setuid/setgid 降权到**原始调用者**（绝不保留 root）
   ├─ 6. chdir 到 /workspace，exec 你的命令
   └─ 7. 命令退出 → 父进程卸载全部挂载 + 删除 jail + 清理临时目录
```

**关键隔离边界（对 agent 是强最小权限）：**
- 文件系统：唯一可写宿主目录就是 `workspace`；其它一切是只读 `nullfs` 或全新 `tmpfs`；`/` 被明确拒绝。
- 网络：**默认无网络**（`ip4=disable`、`ip6=disable`）。需要联网时显式 `--network` 或环境变量 `DSH_JAIL_NETWORK=1`。
- 资源：`rctl` 限额 `maxproc:deny=256`、`pcpu:deny=90`（见第 2 章 `kern.racct.enable`）。
- 进程视图：`enforce_statfs=2`，jail 内只能看到自己的文件系统。

**为什么需要 setuid-root？**
建 jail、挂载只读系统视图这两步需要 root 特权。但特权**只在建 jail 的那一瞬间、且仍在父进程里**使用；子进程 `exec` 你的命令前已经 `setuid` 降权回调用者。所以二进制必须 setuid-root，但**它不会让你的命令以 root 运行**——这是设计使然，不是提权后门。

**`danger-full-access` 只是逃生舱。** 装好 helper 后 harness 自动选 jail 后端，不需要它。只有当 helper 实在装不上时，才用 `DSH_PERMISSION_MODE=danger-full-access` 让命令完全不隔离地跑（见第 4 章）。

---

## 2. 系统前置条件（FreeBSD 13+，实测 14.x）

### 2.1 内核选项自查（JAIL / NULLFS / TMPFS / DEVFS / RACCT / RCTL）

FreeBSD **GENERIC amd64 默认内核已包含** JAIL、NULLFS、TMPFS、DEVFS、RACCT、RCTL。你**不需要**重新编译内核。

⚠️ **一个容易踩的坑（已实测）**：在 stock GENERIC 内核上，`config -x /boot/kernel/kernel` **不一定**会把这些选项逐条列出来。在本机 14.3 上实测，`config -x | grep -iE 'jail|nullfs|devfs'` 返回 **0 行**（只有 RACCT/RCTL/TMPFS 出现）。所以**不要**把"config -x 里没看到 JAIL"当成"内核缺了 jail"——那是 config -x 的行为，不是内核缺功能。**真正权威的自检是：第 5 章 `verify-sandbox.mjs` 跑出 10/10。**

可用这些命令逐项确认能力确实存在：

```sh
# nullfs：以可加载模块形式存在则能看到（本机：nullfs.ko 已加载）
kldstat -n nullfs
# 预期输出示例：
# Id Refs Address                Size Name
#  3    1 0xffffffff821d8000     97f8 nullfs.ko

# tmpfs：编译进 GENERIC，没有独立 .ko 是正常的——说明它常驻内核
kldstat -n tmpfs || echo "tmpfs 已编译进内核（无独立模块，属正常）"

# devfs：总是挂载在 /dev
mount | grep -w devfs
# 预期： devfs on /dev (devfs)

# jail：看 sysctl 命名空间即可确认内核支持
sysctl security.jail 2>/dev/null | head -1

# RACCT/RCTL 是否进内核（config -x 能看到的就这些）
config -x /boot/kernel/kernel 2>/dev/null | grep -iE 'RACCT|RCTL'
```

**出错了怎么办**：若 `kldstat -n nullfs` 报错且你用的是最小化内核，在 `/boot/loader.conf` 加 `nullfs_load="YES"` 后重启（见 2.2）。若 `config -x | grep -iE 'RACCT|RCTL'` 为空，说明内核没编 RACCT/RCTL——但 GENERIC 一定编了，遇到这种情况基本是你用了非 GENERIC 内核，需换回 GENERIC 或自行编入 `options RACCT` / `options RCTL`。

### 2.2 `loader.conf`：开启 rctl 资源限额

`dsh-jail-run.c` 里的 `apply_rctl()` 会给每个 jail 加 `maxproc` / `pcpu` 上限。它调用 `rctl`，而 rctl 要求内核 RACCT **在运行时已启用**。

检查当前是否启用：

```sh
sysctl kern.racct.enable
# 预期： kern.racct.enable: 1
```

若为 `0`，在 `/boot/loader.conf` 写入并**重启**生效：

```sh
# 需要 root
echo 'kern.racct.enable=1' >> /boot/loader.conf
# 同时顺手保证 nullfs 模块一定可用（GENERIC 已内置，这行无害）
echo 'nullfs_load="YES"' >> /boot/loader.conf
reboot
```

⚠️ **行为说明（读 `dsh-jail-run.c` 确认）**：`apply_rctl()` 用 `system()` 执行 `rctl -a ... 2>/dev/null`，**失败被静默忽略**（stderr 丢弃、不告警、不影响建 jail）。也就是说：如果 `kern.racct.enable` 没开，jail **照样能跑**，只是**没有 maxproc/pcpu 限额**。所以这是"加固项"不是"必需项"——但生产环境建议开着。

### 2.3 `rc.conf` 与 `devfs.rules`：ruleset 4 的含义

`rc.conf` 里通常只需确保 devfs 在开机启用（绝大多数情况默认已开，无需改动）。本机 `/etc/rc.conf` 只有一行 `devfs_system_ruleset="vbox"`，与 jail 沙盒无关，不用动。

**ruleset 4 是什么**：`dsh-jail-run.c` 在挂载 `/dev` 时手写 `mount -t devfs -o ruleset=4 devfs <dst>`。ruleset 4 即系统内置的 **`devfsrules_jail`**（jail 专用设备规则：只暴露 `null`/`zero`/`random`/`tty`/`pty*` 等，不给 `mem`/`kmem`/`io` 等危险设备）。它是 FreeBSD 的**默认 jail 规则集**，随系统自带，**不需要你在 `/etc/devfs.rules` 里额外定义**。

```sh
# 你本机的 /etc/devfs.rules 可能只有别的东西（本机是 vbox=10），这完全没问题：
cat /etc/devfs.rules
# [vbox=10]
# add path 'vboxnetctl' mode 0666 group operator
# ...

# ruleset 4 由系统默认提供；确认它在（需要 root 看 defaults）：
# (普通用户可能 Permission denied，属正常；能看更好)
sudo grep -i jail /etc/defaults/devfs.rules 2>/dev/null || echo "（需 root 才能读 defaults，但不影响使用）"
```

**出错了怎么办**：如果沙盒里 `/dev` 设备异常（如 `bash` 起不来、提示缺 `/dev/null`），先确认 `devfs` 在内核（2.1 已查）。ruleset 4 缺的唯一可能是你手动改过 `/etc/defaults/devfs.rules` 把它删了——恢复默认即可，或改 `dsh-jail-run.c` 里的 `ruleset=4` 为你的自定义 ruleset 号（不推荐）。

### 2.4 其它默认行为

- `security.jail.enforce_statfs` 系统默认 **2**（jail 只看得到自己的文件系统）。`dsh-jail-run.c` 也会对每个 jail 显式设 `enforce_statfs=2`，双保险。
- tmpfs / nullfs 在 GENERIC 内置，无需额外 `kldload`（2.1 已确认 nullfs 模块已加载）。

---

## 3. 编译与安装 setuid 二进制（重点，最易错）

源码：`freebsd/dsh-jail-run.c`。编译后需要一个 setuid-root 的安装位置。

### 3.1 常规安装（/usr 可写时）

```sh
# 在仓库根目录操作
cd /home/workbuddy/github/deepseek-harness   # 换成你的仓库路径

# 1) 编译（链接 libjail）
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c

# 2) 以 root 安装为 setuid-root：owner=root:wheel，权限 4755
install -o root -g wheel -m 4755 dsh-jail-run /usr/local/sbin/dsh-jail-run
```

**预期输出**：编译无报错；`ls -l /usr/local/sbin/dsh-jail-run` 看到：

```
-rwsr-xr-x  1 root wheel  21312  ...  /usr/local/sbin/dsh-jail-run
```

注意开头是 **`-rws`**（s 在 owner 执行位 = setuid）。

### 3.2 ⚠️ 本机特例：/usr 只读 → 装到 /var

**本机 `/usr` 是只读挂载**，不能写 `/usr/local/sbin`。所以二进制要装到 `/var` 下，并用 `DSH_JAIL_RUN_BIN` 指过去：

```sh
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c
install -o root -g wheel -m 4755 dsh-jail-run /var/dsh-jail-run
```

`freebsd/dsh-web-run.sh` 启动器已默认把 `DSH_JAIL_RUN_BIN` 指向 `/var/dsh-jail-run`，所以本机直接用它即可。手动验证：

```sh
ls -l /var/dsh-jail-run
# -rwsr-xr-x  1 root wheel  22240  ...  /var/dsh-jail-run
```

**出错了怎么办**：
- 编译报 `cannot find -ljail` → 没装 jail 开发库：`pkg install -y libjail` 或缺头文件；FreeBSD 基础系统一般自带 `/usr/include/jail.h` 和 `/usr/lib/libjail.*`，若被精简需补装 `FreeBSD-headers`/`libjail`。
- `cc: command not found` → `pkg install -y llvm` 或用 `cc`（基础系统自带 clang，应存在）。

### 3.3 ⚠️ 二进制必须落在"非 nosuid"文件系统

setuid 位只有在**非 `nosuid` 挂载**的文件系统上才生效。本机 `/tmp` 就是 nosuid 的 ZFS 数据集：

```sh
mount | grep -iE 'nosuid|tmpfs' | grep -w /tmp
# zroot/tmp on /tmp (zfs, local, noatime, nosuid, nfsv4acls)   ← 看到 nosuid 就绝不能放这
```

**结论：绝对不要把 `dsh-jail-run` 装到 `/tmp` 或任何带 `nosuid` 挂载点的目录**（包括 `/var/tmp`，本机同样是 nosuid）。否则内核会忽略 setuid 位，二进制以调用者身份跑、无法建 jail，报 `SANDBOX_UNAVAILABLE`。`/usr/local/sbin` 与 `/var` 都是正常挂载，安全。

### 3.4 验证 setuid + 自动降权

非 root 用户应当能直接执行它（它会自动降权到调用者）：

```sh
# 用普通用户（如 workbuddy）跑，确认能建 jail 且以自己身份运行：
dsh-jail-run --workspace "$HOME" --mode read-only -- id
# 预期：在 jail 内打印调用者的 uid/gid（不是 0），且 cwd 为 /workspace
```

**出错了怎么办**：若 `permission denied` 或 `operation not permitted` 在建 jail 阶段，检查 (a) 文件权限确实是 `-rwsr-xr-x root wheel`；(b) 所在文件系统非 nosuid（3.3）；(c) 你用的是普通用户执行（root 执行时 `getuid()==0`，降权后仍 0，属正常但无演示意义）。

### 3.5 安全声明（务必读完再继续）

`setuid-root` 是把双刃剑。本二进制的设计把特权严格收束：

- 二进制**只在建 jail + 挂载只读系统视图时短暂为 root**，随后子进程立刻 `setuid` 回调用者。**绝不静默提权**：没有 setuid 位时，该程序只能在"已经 root"时建 jail，而 harness 永远不会授予你 root。
- 你传入的 `workspace` 是**唯一**暴露的可写宿主目录；其余一切是只读 `nullfs` 或全新 `tmpfs`；明确拒绝 `/`。
- 二进制必须 **root 所有、且组/其他不可写**，并放在非 root 用户**不能改名/替换**的目录里（`/usr/local/sbin`、`/var` 都满足）。如果你把二进制放到一个普通用户可写的目录，本地任意用户就能替换它、以 root 执行任意代码——**这是 setuid 二进制的头号风险**。
- 升级/重装二进制必须用 root，且要重新 `install`（见第 8 章）。

---

## 4. 配置与启动 web 服务

### 4.1 `freebsd/dsh-web-run.sh` 做了什么

启动器位于 `<repo>/freebsd/dsh-web-run.sh`，按自身位置推导仓库根，**无需改路径**。关键点：

- **默认不强制 `danger-full-access`**。它只在环境变量 `DSH_PERMISSION_MODE` 已设置时才导出它；否则留空，让 harness 自己选默认的受限模式（即 jail 沙盒）。装好 helper 后，这就是你想要的。
- 把 `DSH_JAIL_RUN_BIN` 默认指向 `/var/dsh-jail-run`（适配本机只读 `/usr`；若是常规安装则在命令里用 `DSH_JAIL_RUN_BIN=/usr/local/sbin/dsh-jail-run` 覆盖）。
- 把 `node`/`pnpm`（来自 `/usr/local`）和 `~/bin/make` shim 加进 `PATH`（兼顾交互 shell 与 rc.d 启动的最小 PATH）。
- `cd` 进 `DSH_PROJECT_DIR`（默认仓库根），再 `exec pnpm dsh:freebsd web`。

### 4.2 启动方式（daemon 持久化 + loopback 绑定）

仓库自带一键控制脚本 `freebsd/dsh-web-restart.sh`（`[stop|start|restart|status]`，默认 `restart`）：

```sh
cd /home/workbuddy/github/deepseek-harness
sh freebsd/dsh-web-restart.sh restart
# 或： stop / start / status

# 想让所有命令默认落在某个项目目录（而非仓库根）：
DSH_PROJECT_DIR=/home/workbuddy/dswork sh freebsd/dsh-web-restart.sh restart
```

底层用 `/usr/sbin/daemon` 把 web 持久化，**日志与 pidfile 放在 home 目录**（`/home/workbuddy/dsh_web.log`、`/home/workbuddy/dsh_web.pid`），避开 `/tmp` 清理、重启不丢。

**预期输出**：`status` 应看到 `dsh:freebsd web` 进程在跑；`tail -f /home/workbuddy/dsh_web.log` 看到监听 `http://127.0.0.1:3080`。

开机自启（需 root，详见 `FREEBSD.md` §11）：

```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
service dsh_web start
```

### 4.3 ⚠️ 必须走 loopback（127.0.0.1:3080）+ SSH 隧道，否则 host RPC 信任围栏返回 HTTP 403

Web UI **只监听 `127.0.0.1:3080`**（环回地址）。这不是配置开关，是 harness 故意的 **confused-deputy / DNS-rebinding 防护**：host 类 RPC（如"选择工作区目录" `host.listDirectory`）要求请求的 `Host` 必须是 loopback，否则直接 `HTTP 403`——**无法用配置绕过**。

- **本机**直接开 `http://127.0.0.1:3080` 即可。
- **远程访问只能走 SSH 隧道**（在你本地工作站执行）：

```sh
ssh -L 3080:127.0.0.1:3080 workbuddy@192.168.1.5
# 然后浏览器开 http://localhost:3080
```

隧道同时解决了两件事：loopback `Host`（无 403）+ 安全上下文（原生 `crypto.randomUUID` 可用，避免 `crypto.randomUUID is not a function`）。

**出错怎么办**：若通过反向代理 / LAN IP / 公网域名开 UI，即使 web 进程正常，`host.listDirectory` 等也会 `HTTP 403`。一律改回 SSH 隧道或本机 `localhost`。不要用 LAN IP 直接做目录/文件操作。

### 4.4 `danger-full-access` 逃生舱（仅排障时）

helper 装不上、或你要临时让某次启动完全不隔离时：

```sh
# 方式一：启动器识别 DSH_PERMISSION_MODE 并透传
DSH_PERMISSION_MODE=danger-full-access sh freebsd/dsh-web-restart.sh restart

# 方式二：直接在 harness 侧（UI 里选 danger-full-access 权限预设）
```

⚠️ 这会**关闭 jail 隔离**，命令直接跑在宿主上。仅排障或 helper 不可用短时使用，不要作为常态。

---

## 5. 验证（照抄即可确认成功）

### 5.1 运行时自检：10/10

仓库自带 `freebsd/verify-sandbox.mjs`，它调用**真实的**（已构建的）本地沙盒 lib，按 web 服务的方式生成 argv、真正 spawn setuid helper，并断言隔离事实。

```sh
cd /home/workbuddy/github/deepseek-harness
DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs
```

**预期输出（10/10）**：

```
PASS confine selects jail bin
PASS enforcement is full
PASS mode flag passed
PASS workspace flag passed
PASS read-only write denied (non-zero)
PASS denied file absent on host
PASS workspace-write write ok
PASS written file on host
PASS cwd is /workspace
PASS no network resolution

== SUMMARY: PASS=10 FAIL=0 ==
```

逐条含义：
1. `confine selects jail bin` —— harness 选中的后端确实是 `dsh-jail-run`（而不是 fail-closed）。
2. `enforcement is full` —— 后端声明"完全隔离"（read-only 只读绑定 / workspace-write 读写绑定，承诺的文件效果全部受控）。
3. `mode flag passed` —— argv 里带 `--mode read-only`。
4. `workspace flag passed` —— argv 里带 `--workspace <root>`。
5. `read-only write denied` —— read-only 下往 `/workspace` 写被拒（EROFS，非 0 退出）。
6. `denied file absent on host` —— 被拒的写入**没有**漏到宿主 workspace。
7. `workspace-write write ok` —— workspace-write 下写入成功。
8. `written file present on host` —— 写入确实落在宿主对应路径（验证 workspace 重绑定正确）。
9. `cwd is /workspace` —— 命令在 jail 内落在 `/workspace`。
10. `no network resolution` —— jail 内**无法**解析域名（默认无网络）。

> 注：本机实测 `verify-sandbox.mjs` 结果为 **PASS=10 FAIL=0**，与上面一致。

### 5.2 e2e 测试：5/5

集成测试 `packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts` 通过 `confine()` + 真实 helper 断言世界影响、包装形状、内核拒绝方言。

```sh
cd /home/workbuddy/github/deepseek-harness
pnpm vitest run --config vitest.e2e.config.ts packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts
```

**预期输出（5/5）**：

```
 Test Files  1 passed (1)
      Tests  5 passed (5)
```

> 注：本机实测 e2e 为 **5 passed (5)**。该测试在非 FreeBSD 或 helper 缺失时自动 skip。

### 5.3 web 日志零 `SANDBOX_UNAVAILABLE`

沙盒正常运行时，受限模式应全部走 jail，不应有"无后端可用"的报错。

```sh
grep -c SANDBOX_UNAVAILABLE /home/workbuddy/dsh_web.log
# 预期： 0
```

同时确认 web 进程**没有**以 `danger-full-access` 运行（除非你故意）：

```sh
ps -ww -o pid,command -U workbuddy | grep 'dsh:freebsd web' | grep -v grep
# 预期：能看到 node ... pnpm dsh:freebsd web，且不带 DSH_PERMISSION_MODE=danger-full-access
```

**出错了怎么办**：若 `grep -c` 大于 0，说明有命令因沙盒不可用而 fail-closed——回到第 3 章检查二进制是否 setuid、路径、所在文件系统。

---

## 6. 排错表（现象 → 原因 → 解决）

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `SANDBOX_UNAVAILABLE`：`sandbox mode "..." is requested but no sandbox backend is usable` | `dsh-jail-run` 缺失 / 未 setuid / `DSH_JAIL_RUN_BIN` 指错路径 | 回到第 3 章：(1) 确认二进制存在 `ls -l /var/dsh-jail-run`；(2) 权限是 `-rwsr-xr-x root wheel`；(3) 启动器或命令里 `DSH_JAIL_RUN_BIN` 指向正确路径。修好后无需重启 web（每个命令都重新 exec 二进制）。 |
| jail 内 `/tmp` 报 `Permission denied` | 旧二进制没做 `chmod 01777 /tmp`（已在修复版处理） | **重装新构建**：`cc ... && install -o root -g wheel -m 4755 dsh-jail-run /var/dsh-jail-run`。当前 `/var/dsh-jail-run`（Aug 16 19:59 构建）已含 /tmp 可写修复。 |
| `libintl.so.8: not found` 之类共享库缺失 | `dsh-jail-run.c` 会 nullfs 挂载宿主的 `/var/run/ld-elf.so.hints` 让 jail 内能找到 `/usr/local/lib` 的库；若**宿主本身**缺 hints 文件或库，则异常 | 宿主上 `ls -l /var/run/ld-elf.so.hints` 应存在；缺失则 `service ldconfig restart` 重建。库缺失则 `pkg install` 对应包。 |
| `Resource deadlock avoided` (EDEADLK) | nullfs **嵌套**挂载（如把 `/usr` 整体挂了又在其下挂 `/usr/local`） | 这是 FreeBSD nullfs 的已知限制，代码已规避：只挂具体子目录（`/usr/bin`、`/usr/local` 等），**不**整体挂 `/usr`。若你改了 `SYS_RO_MOUNTS` 引入嵌套，拆开即可。 |
| jail 内竟能联网（如 `getent hosts github.com` 有结果） | `ip4`/`ip6` 被错误设为 `inherit` 或 `--network` 被误开 | 默认 `ip4=ip6=disable`。检查是否设了 `DSH_JAIL_NETWORK=1` 或传了 `--network`；去掉即恢复无网络。 |
| 共享库缺失（除 libintl 外的 `.so`） | 目标程序依赖的库不在 jail 的只读视图里 | jail 只读视图已覆盖 `/lib /usr/lib /usr/local` 等标准路径；若你的命令依赖非标准路径的库，把它加进 `SYS_RO_MOUNTS`（需重编译），或改在 workspace 内自带。 |
| `command not found` / `exec ...: No such file or directory` (ENOENT) | jail 内没有该命令（只读视图未覆盖其所在目录） | 确认命令在 `/bin /usr/bin /usr/local/bin` 之一；否则换用 jail 内存在的解释器，或扩充 `SYS_RO_MOUNTS`。 |
| web UI 打开后"选择工作区目录"等报错 `HTTP 403` | 非 loopback `Host`（用了 LAN IP / 反代 / 公网域名） | 一律改走 SSH 隧道或本机 `localhost`（见 4.3）。这是信任围栏，**不能靠配置绕过**。 |
| 编译报 `cannot find -ljail` | 缺 jail 库/头文件 | 基础系统应自带；若被精简，`pkg install -y libjail`（并确认 `/usr/include/jail.h` 存在）。 |
| 升级二进制后行为没变 | 忘了重新 `install`（只是 `cc` 出了新文件，没替换已安装的 setuid 副本） | 升级必须 `install -o root -g wheel -m 4755 dsh-jail-run <目标路径>`（见第 8 章）。通常无需重启 web。 |

---

## 7. 安全与威胁模型

**隔离边界是什么（以及不是什么）：**
- **是**：对 agent 而言是**强最小权限**——文件系统只剩 `workspace` 可写、其余只读、全新 `/tmp`、默认无网络、进程视图受限、资源有 rctl 上限。一个被 prompt 注入的 agent 很难借 jail 读到 workspace 之外的宿主文件或对外发请求。
- **不是**：这不是对抗**内核漏洞利用**的完整沙箱。如果 jail 自身的内核实现有提权漏洞，隔离会被打破。它也不防"宿主上已有凭证被读取"（如 workspace 内放了的 `.env`）——最小权限不等于秘密管理。

**setuid 审计要点（每次升级/重装都复核）：**
1. `ls -l` 确认 owner=root:wheel、权限 `4755`（`-rwsr-xr-x`）、**组/其他不可写**。
2. 所在目录非普通用户可写、非 `nosuid` 挂载（第 3.3 章）。
3. 二进制内容来自可信源码（`freebsd/dsh-jail-run.c`），不要从未知来源拷二进制。
4. 任何修改源码后重新编译安装，都要重新走第 3 章流程。

**日志里不该出现的内容：**
- 不该有 `dsh-jail-run:` 的 runner 失败行（那是校验/挂载/jail 创建失败，退出 125）——出现说明 helper 自身出错，按第 6 章查。
- 不该有 `SANDBOX_UNAVAILABLE` 大量刷屏（说明 helper 不可用，命令被 fail-closed）。
- 正常日志里能看到 jail 被创建/拆除，但**不应**出现任何命令以 uid 0 在 jail 外执行的痕迹。

**升级/重装二进制的注意事项：**
- 必须用 root 执行 `install`，保证 owner/权限正确。
- 若二进制曾被普通用户目录引用，先确认新路径同样满足"非 nosuid、非用户可写"。
- 重装后建议立刻跑第 5.1 的 `verify-sandbox.mjs` 确认 10/10。

---

## 8. 升级与重装

改了 `freebsd/dsh-jail-run.c` 后，需要重新编译 + 以 root 重装 setuid 二进制。

### 8.1 重新编译 + 重装（需 root）

```sh
cd /home/workbuddy/github/deepseek-harness

# 常规安装位置（/usr 可写）
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c
install -o root -g wheel -m 4755 dsh-jail-run /usr/local/sbin/dsh-jail-run

# 或本机只读 /usr → 装到 /var
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c
install -o root -g wheel -m 4755 dsh-jail-run /var/dsh-jail-run
```

### 8.2 web 是否需要重启？

**通常不需要。** 每个被下发的命令都会**重新 `exec` 一次 `dsh-jail-run` 二进制**——它不在 web 进程里常驻。所以重装二进制后，下一条命令就会用新二进制，无需重启 web 服务。

唯一需要重启 web 的情况：你改的是 web 启动器（`dsh-web-run.sh`）或 harness 自身源码（那要先 `pnpm run build`，见 `FREEBSD.md` §8）。

### 8.3 升级后验证

```sh
ls -l /var/dsh-jail-run        # 确认 -rwsr-xr-x root wheel，且 mtime 是刚装的
DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs   # 预期 10/10
```

---

## 附：已验证状态（本机 192.168.1.5，FreeBSD 14.3-RELEASE-p7）

- `/var/dsh-jail-run`：`-rwsr-xr-x root wheel`，新构建（含 /tmp 可写修复）。
- `node freebsd/verify-sandbox.mjs` → **PASS=10 FAIL=0**。
- e2e `freebsd-jail.e2e.ts` → **5 passed (5)**。
- web 受限模式运行在 `127.0.0.1:3080`，`dsh_web.log` 中 `SANDBOX_UNAVAILABLE` 计数为 **0**。
- 提交 `89a52eedda` 已推 github / gitea / gitcode 三远端。

相关源码（改文档前请先读，确保与代码一致）：
- `freebsd/dsh-jail-run.c` —— setuid-root jail runner。
- `freebsd/dsh-web-run.sh` —— web 启动器（不设 `danger-full-access`、指 `DSH_JAIL_RUN_BIN`）。
- `packages/sandbox/sandbox-local/src/index.ts` —— `freebsd-jail` runner 的 TS 接线（`PLATFORM_CHAINS` / `probeRunner` / `runnerArgv` / `RUNNER_FAILURE_RULES`）。
- `packages/sandbox/sandbox/src/index.ts` —— `sandboxUnavailableHint()` 的 FreeBSD 分支。
- `freebsd/verify-sandbox.mjs` —— 10 项运行时自检。
- `packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts` —— e2e 测试。
