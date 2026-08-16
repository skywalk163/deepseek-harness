# DeepSeek Harness 在 FreeBSD 上的安装与运行手册

> **重要：FreeBSD 请用本 fork（`skywalk163/deepseek-harness`），不要克隆上游 `deepseek-ai/deepseek-harness`。**
> FreeBSD 移植补丁（`process-inspector` 的 ps 语法修复、`terminal-bash` 默认 shell 修复、`crypto.randomUUID` polyfill、仅环回地址的信任围栏）**尚未合并到上游**，只维护在本仓库。克隆上游会缺少这些修复。

本手册把从「全新 FreeBSD」到「`dsh web` 跑起来」的所有步骤串成一条线，新手照抄命令即可装成功。所有命令均已在 FreeBSD 14.3-RELEASE amd64（Node 24）验证；FreeBSD 15.x 同样适用（第 2 步已覆盖 15.1 上 `pnpm install` 报错的根因与修复）。

---

## 0. 适用范围与前置认知

- **需要权限**：装 pkg 软件需要 `root`（或用 `sudo`/`doas`）；跑服务用一个普通用户（本文以 `workbuddy` 为例）。
- **网络**：仓库根 `.npmrc` 已把 `registry` 和 `disturl` 指向 npmmirror 镜像，中国大陆拉取 Node 头文件 / FreeBSD 平台 tarball 更稳。海外用户可删掉这两行改用默认源。
- **安全围栏（硬限制，不是配置开关）**：Web UI 只监听 `127.0.0.1:3080`（环回地址）。任何反向代理、LAN IP、公网域名访问一律被 `HTTP 403` 拒绝。远程访问**只能走 SSH 隧道**（见第 10 步）。

---

## 1. 安装系统级前置软件（root 或 sudo/doas）

```sh
pkg update
pkg install -y node24 npm-node24 gmake python3 pkgconf bash ripgrep
```

| 包 | 作用 |
| --- | --- |
| `node24` | Node.js 24（`engines` 要求 `^22.19.0 \|\| >=24.0.0`） |
| `npm-node24` | 随 Node24 的 npm（FreeBSD 上 npm 是独立包，`node24` 不自带） |
| `gmake` | GNU make。`/usr/bin/make` 是 BSD make，node-gyp 需要 GNU make，第 3 步做 shim |
| `python3` | `node-pty` 编译用（验证 3.11 / 3.12 均可） |
| `pkgconf` | node-gyp / Node 头文件探测 |
| `bash` | **硬依赖**，见第 4 步，FreeBSD 默认不装 |
| `ripgrep` | 提供系统 `rg` 二进制；当随包自带的 `@vscode/ripgrep` 在 FreeBSD 无原生二进制时，`grep` / `glob` 工具会回退到它（见第 9 步与排错表） |

验证版本：

```sh
node -v        # v24.x
npm -v         # 11.x
bash --version # 5.x
gmake --version
python3 --version
```

---

## 2. 关键坑：pnpm 必须用 npm 安装，禁用 corepack（15.1 报错根因）

### 现象

在 FreeBSD 15.1（以及任何通过 **corepack / standalone** 方式安装 pnpm 的 FreeBSD）上执行 `pnpm install` 会报：

```
[ERROR] Cannot verify the identity of the @pnpm/exe.freebsd-x64 native binary:
        it is missing from pnpm-lock.yaml
```

### 根因

pnpm v10 / v11 把自身打包成平台原生二进制 `@pnpm/exe-<os>-<arch>`。当 pnpm 以 **corepack / standalone** 方式运行时，它会去 `pnpm-lock.yaml` 校验这个原生二进制的身份。而本仓库的 `pnpm-lock.yaml` 是在**其它平台用 npm 版 pnpm** 生成的，里面**没有任何 `@pnpm/exe` 条目**（已确认：lockfile 含 80 处 `freebsd` 引用，但 0 处 `@pnpm/exe` / `exe-freebsd-x64`）。FreeBSD 上自然也找不到 `freebsd-x64` 的 exe 条目 → 校验失败。

### 修复 / 预防（务必照做）

**用 npm 安装 pnpm，不要启用 corepack。**

```sh
# 全局安装（root 或你的用户均可）。
# 这会装成纯 JS 启动器 pnpm.cjs，运行于 node，
# 不触发 @pnpm/exe 身份校验，所以在 FreeBSD 上能成功。
npm install -g pnpm@11.7.0
```

> ⚠️ **不要**执行 `corepack enable` 或 `corepack prepare pnpm@...`。corepack 会把 pnpm 装成 standalone 原生二进制路径——那正是触发上面报错的那条路。
>
> **版本说明**：仓库 `package.json` 的 `packageManager` 固定为 `pnpm@11.7.0`，建议对齐；但只要是 **npm 安装的** pnpm（本机现跑的 10.28.0 也是 JS 启动器）都能用——**方法比版本更关键**。

验证 pnpm 确实是 JS 启动器（正确形态）：

```sh
readlink -f "$(which pnpm)"
# 应指向 .../node_modules/pnpm/bin/pnpm.cjs
head -1 "$(which pnpm)"
# 应为 #!/usr/bin/env node
pnpm -v
```

如果你已经用 corepack 装过、卡在报错，先清掉 corepack 的 shim 再按上面重装：

```sh
corepack disable 2>/dev/null
npm install -g pnpm@11.7.0
```

---

## 3. GNU make shim（node-gyp 需要）

FreeBSD 的 `/usr/bin/make` 是 BSD make，而 node-gyp 必须调用 GNU make 且命令名要是 `make`。做软链并放到 `PATH` 最前面：

```sh
mkdir -p "$HOME/bin"
ln -sf /usr/local/bin/gmake "$HOME/bin/make"

# 写入 shell 启动文件，使每次登录都生效：
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.shrc
# 若你用 bash 登录，则写 ~/.bashrc：
# echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

重新登录或 `source ~/.shrc`，然后验证：

```sh
which make       # 应指向 $HOME/bin/make -> /usr/local/bin/gmake
make --version   # GNU Make 4.x
```

---

## 4. bash 硬依赖（terminal-bash 后端）

`code` / `mini` 两种 agent 模式依赖 `terminal-bash` 后端，它用到 bash 专有特性：

- `PROMPT_COMMAND` 输出每命令结束的 OSC `133;D;` 标记，harness 据此判断命令何时结束、退出码是多少；
- 默认 shell 参数 `--noprofile --norc -i` 是 bash 专有。

FreeBSD 默认 shell 是 `/bin/sh`（ash 衍生），**不能替代 bash**。bash 缺失会报 `PTY shell exited during startup`（或明确提示 `terminal-bash: ... does not exist`）。

```sh
pkg install -y bash    # 第 1 步已装；确认一下
which bash             # /usr/local/bin/bash
```

仓库已在 `packages/terminal/terminal-bash/src/config.ts` 加了校验：shellPath 不存在 / 非 bash 时会直接报清晰错误，而不再静默回退到不存在的路径。

---

## 5. .npmrc（node-pty 需要 Node 头文件）

仓库根 `.npmrc` 已含：

```
registry=https://registry.npmmirror.com
fetch-retries=5
fetch-retry-maxtimeout=120000
fetch-timeout=300000
disturl=https://registry.npmmirror.com/-/binary/node
```

`disturl` 让 `node-pty` 编译时**自动下载对应 Node 头文件**，无需手动指定 `--nodedir`。保持这两行（`registry` / `disturl`）。海外用户可改用默认 registry（删前两行），但务必保留能访问 Node 头文件的能力。

---

## 6. 克隆仓库（从咱们自己的 fork）

```sh
cd ~
git clone https://gitcode.com/skywalk163/deepseek-harness.git
# 或 GitHub 镜像：
# git clone https://github.com/skywalk163/deepseek-harness.git
cd deepseek-harness
git log --oneline -1   # 应看到 FreeBSD 移植相关提交
```

> 不要克隆上游 `deepseek-ai/deepseek-harness`——FreeBSD 补丁尚未合并，上游缺这些修复。

---

## 7. 安装依赖

```sh
pnpm install
```

这一步会编译 `node-pty` 原生插件（依赖第 1 / 3 / 5 步的 gmake、python3、pkgconf、disturl）。若卡在 ETIMEDOUT 拉 Node 头文件，检查 `.npmrc` 的 `disturl` 与网络连通性。

---

## 8. 构建

改了源码后必须重新构建（web 命令只服务预编译产物 `apps/web/dist`）：

```sh
pnpm run build     # 等价于 build:lib (tsc -b + tsdown) + build:web (vite)
```

---

## 8.1 启用 FreeBSD jail 沙箱（推荐）

与其让 agent 以非隔离方式运行（`danger-full-access`），你可以把每条 `code` / `mini` / `standard` 命令都关进**真正的 FreeBSD jail** 里。只要装好 setuid 的 `dsh-jail-run` helper，harness 的本地沙箱 provider 会在 FreeBSD 上自动选这个后端——无需 `danger-full-access`。

### 编译并安装 setuid helper（root）

```sh
cc -O2 -Wall -ljail -o /usr/local/sbin/dsh-jail-run freebsd/dsh-jail-run.c
chmod 4755 /usr/local/sbin/dsh-jail-run
chown root:wheel /usr/local/sbin/dsh-jail-run
```

在 `/usr` 是**只读挂载**的机器上（本机即是），把二进制写到 `/var` 下，并用 `DSH_JAIL_RUN_BIN` 指过去：

```sh
cc -O2 -Wall -ljail -o /var/dsh-jail-run freebsd/dsh-jail-run.c
chmod 4755 /var/dsh-jail-run
chown root:wheel /var/dsh-jail-run
# freebsd/dsh-web-run.sh 启动器已默认把 DSH_JAIL_RUN_BIN 指向 /var/dsh-jail-run
```

### 安全须知（改这个文件前先读 `freebsd/dsh-jail-run.c` 顶部注释）

- 该二进制是 **setuid-root**。任何能执行它的本地用户都能建 jail——但命令始终在 jail **内部以原始（非 root）调用者 uid/gid** 运行。root 只用于 (a) 建 jail 和 (b) 挂载只读系统视图，随后在子进程里用 `setuid`/`setgid` 降权。**不存在静默提权**：没有 setuid 位时，该程序只能在已是 root 时建 jail，而 harness 永远不会授予 root。
- 你传入的 workspace 是**唯一**暴露的可写宿主机目录。其余一切都是只读 `nullfs` 挂载或全新 `tmpfs`；jail 默认**无网络**（用 `--network` 或 `DSH_JAIL_NETWORK` 显式开启）。
- 二进制必须 root 所有、且组/其他不可写，并放在非 root 用户不能改名/替换的目录里。

### 后端做了什么

`dsh-jail-run --workspace <root> --mode <read-only|workspace-write> -- <command...>` 在一个临时目录里建一个临时 jail，把宿主系统以只读方式挂载 + workspace（只读或读写）+ 受限 `devfs`（ruleset 4）+ 全新 `tmpfs` 挂到 `/tmp`，`jail_attach` 进去，降权到调用者，`chdir` 到 `/workspace`，再 `exec` 命令。命令退出后 jail 被拆除（挂载一并卸载）。harness 为 `read-only` / `workspace-write` 接上这个后端；`danger-full-access` 仍是显式逃生舱。

### 验证

```sh
sh /tmp/dsh-jail-test.sh   # 降权到调用者 uid、cwd=/workspace、只读拒绝写入、
                            # 无网络、干净拆除（9/9 通过）
```

（完整契约见 `freebsd/dsh-jail-run.c` 与 `freebsd-jail.e2e.ts` 测试。）

---

## 9. 运行 Web UI

```sh
pnpm dsh:freebsd web                       # 默认受限（若装了 helper 则走 jail 沙箱）
# 或整机退出沙箱（显式逃生舱）：
DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
```

- **默认工作目录。** harness 把每条 `bash` / `grep` / 终端命令的 cwd 都走 `session.header.cwd`，当 Web UI 没有设置"每任务项目目录"时，它会回退到 `process.cwd()`（即本命令所在目录）。若从仓库根启动，命令默认就在仓库里——想指定项目，用 `DSH_PROJECT_DIR` 环境变量（`freebsd/dsh-web-run.sh` 启动器认这个变量；否则启动前先 `cd` 进你的项目）。在本 fork 把任务"项目目录"字段接进 `header.cwd` 之前，这是让项目成为默认工作目录的可靠办法。

- `dsh:freebsd` = 普通 `dsh` + `--expose-internals`。FreeBSD 上 HMR 服务必须该 flag，且**不能**经 `NODE_OPTIONS` 传（`node-addon-require-builtin` 只发布 darwin/linux/win32 预编译，FreeBSD 无原生包也无源码兜底）。
- **FreeBSD 现已自带 jail 沙箱后端（推荐）。** 只要装好 setuid 的 `dsh-jail-run` helper（见 8.1 节），本地沙箱 provider 会在 FreeBSD 上自动选一个真正的 jail——于是 `read-only` / `workspace-write` 模式会跑在 **jail 内部**，而非 fail-closed。`danger-full-access` 依旧可用，作为 helper 无法运行时的显式逃生舱（设 `DSH_PERMISSION_MODE=danger-full-access`）。若**未**装 helper，仍是旧行为：受限模式 fail-closed 报 `SANDBOX_UNAVAILABLE`，必须用 `danger-full-access`。
- ⚠️ **`code` / `mini` 模式恰恰是 jail 发力之处——而且是好事。** 它们把持久 PTY bash 会话经由*受沙箱约束的* bash executor 驱动。装了 `dsh-jail-run` 后，每条 `bash`/`ls`/文件命令都关在一个 jail 里运行，其中唯一可写的宿主机目录就是 workspace；workspace 之外文件系统只读、且无网络。若**未**装 helper，会话会中止并报：
  ```
  Error: sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host;
  refusing to run the command unconfined. Install the `dsh-jail-run` setuid helper (see section 8.1)
  or, to opt out, switch to `danger-full-access`: launch with DSH_PERMISSION_MODE=danger-full-access,
  or pick the danger-full-access permission preset in the UI.
  ```
  该报错**是设计如此（fail-closed），并非崩溃。** 装 helper（推荐）或设 `DSH_PERMISSION_MODE=danger-full-access` 退出沙箱。
- 默认监听 `http://127.0.0.1:3080`。

---

## 10. 远程访问：SSH 隧道（唯一被允许的方式）

Web UI **只接受环回地址**（`localhost` / `127.0.0.1` / `[::1]`）。反向代理、LAN IP、公网域名一律 `HTTP 403`（harness 的 host 侧 RPC 信任围栏：非 loopback 的 `Host` 直接被拒，连"选择工作区目录"都会失败）。

在你本机（工作站）执行：

```sh
ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>
```

然后浏览器开 `http://localhost:3080`。隧道同时给了 loopback `Host`（无 403）和安全上下文（原生 `crypto.randomUUID` 可用），两个坑一次消除。

在 FreeBSD 本机直接开 `http://127.0.0.1:3080` 即可。

---

## 11. 作为服务运行（重启用脚本 + rc.d）

仓库自带路径无关的 helper 脚本（`freebsd/` 子目录，按自身位置推导仓库根，clone 到哪都行）。要自定义项目目录，在服务 env 里设 `DSH_PROJECT_DIR`（见下）——启动器会先 `cd` 进去，成为所有命令的默认工作目录。

- `freebsd/dsh-web-run.sh`——启动器：不再强制 `DSH_PERMISSION_MODE`（默认走 harness 的受限模式以启用 jail 沙箱；只有要退出时才设它），把 `DSH_JAIL_RUN_BIN` 指向 helper（本机只读 `/usr` 下默认 `/var/dsh-jail-run`），cd 进 `DSH_PROJECT_DIR`（默认仓库根），`exec pnpm dsh:freebsd web`。
- `freebsd/dsh-web-restart.sh`——一键控制：`stop | start | restart | status`（默认 `restart`）。

```sh
sh freebsd/dsh-web-restart.sh restart   # 也可：stop / start / status
DSH_PROJECT_DIR=/home/skywalk/dswork sh freebsd/dsh-web-restart.sh restart   # 指定项目目录
```

开机自启（需 root）：

```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
sysrc dsh_web_chdir="$(pwd)"          # 仓库绝对路径，自动填入
sysrc dsh_web_projectdir="/home/skywalk/dswork"   # 可选：默认项目目录
service dsh_web start        # 验证
service dsh_web status
```

注意：

- `pnpm` 要持久化（本机在 `/home/workbuddy/.local/bin/pnpm` v11.7.0），别用 `/tmp/p117` 这类重启会被清的路径。
- rc.d 的 `pidfile` 与日志放在仓库内（`dsh_web.pid`、`dsh_web.log`）以避开 `/tmp` 清理、重启不丢。
- rc.d 服务以 `dsh_web_user`（默认 `workbuddy`）运行；装到别处用 `sysrc dsh_web_user=...` 改。

---

## 12. Git：三远端与 lefthook 绕过（仅当你要往回推补丁）

本仓库三远端：

```sh
git remote -v
# origin   https://gitcode.com/skywalk163/deepseek-harness (fetch/push)
# github   git@github.com:skywalk163/deepseek-harness.git
# gitea    http://192.168.1.5:3000/skywalk/deepseek-harness.git
```

提交 / 推送时，**lefthook 的 `gen-third-party-notices` 等钩子会因 `@anthropic-ai/claude-agent-sdk-linux-x64`（仅 Linux 构建）在 FreeBSD 失败**，与你的改动无关。绕过：

```sh
git commit --no-verify
git -c core.hooksPath=/tmp/nohooks push <remote> <branch>
```

（推 gitcode / gitea 时按需在 URL 注入 token，见仓库既有约定。）

---

## 13. 排错表

| 现象 | 原因 | 修复 |
| --- | --- | --- |
| `Cannot verify the identity of the @pnpm/exe.freebsd-x64 native binary: it is missing from pnpm-lock.yaml` | 用 corepack / standalone 装 pnpm，触发 `@pnpm/exe` 身份校验；lockfile 无 freebsd-x64 exe 条目 | **用 `npm install -g pnpm@11.7.0`**（JS 启动器，不校验）；禁用 corepack。见第 2 步。 |
| `Could not load the "sharp" module using the freebsd-x64 runtime` | `sharp` 无 FreeBSD 原生二进制，需走 WASM | 保留 `pnpm-workspace.yaml` 的 `supportedArchitectures`（`os: freebsd`，`cpu` 含 `wasm32`）与 `sharp` `packageExtensions`。 |
| `@deepseek-ai/dsh-client-ui-*` 报 `ERR_MODULE_NOT_FOUND` | 工作区插件未 hoist | 保留 `shamefullyHoist: true`。 |
| `--expose-internals is required for HMR service` | FreeBSD 无 `node-addon-require-builtin` 预编译 | 用 `dsh:freebsd` 脚本（自带 `--expose-internals`）；不能放 `NODE_OPTIONS`。 |
| `code` / `mini` 模式报 `sandbox mode "..." is requested but no sandbox backend is usable`（`SANDBOX_UNAVAILABLE`） | 未装 `dsh-jail-run` setuid helper（FreeBSD 没有**内置**后端，需要这个 helper） | **装上 helper**（见 8.1 节）——受限模式随即跑在 jail 里。或退出沙箱：启动前设 `DSH_PERMISSION_MODE=danger-full-access` / 在 UI 选 **danger-full-access** 预设。设计上的 fail-closed，不是崩溃——见第 9 步。 |
| `crypto.randomUUID is not a function` | 非安全上下文（plain http / 非 localhost） | 经 `http://localhost:3080`（SSH 隧道）访问。 |
| `transport failure for /api/host.listDirectory: HTTP 403` | 环回信任围栏拒绝非 loopback `Host` | 用 SSH 隧道 / `localhost`，别用反代或 LAN IP。 |
| `node-pty` 编译失败 / ETIMEDOUT 拉 Node 头文件 | node-gyp 拉不到头文件 | 保留 `.npmrc` 的 `disturl`；确保 gmake shim 在 `PATH`。 |
| `PTY shell exited during startup` / `terminal-bash: ... does not exist` | 没装 bash（FreeBSD 默认 `/bin/sh`） | `pkg install bash`；该后端不能用默认 sh。 |
| `gen-third-party-notices` 钩子 commit / push 失败 | 上游钩子要 Linux-only 的 claude-agent-sdk | FreeBSD 平台不兼容，与改动无关；`git commit --no-verify` 或 `git -c core.hooksPath=/tmp/nohooks push`。 |
| `grep` / `glob` 报 `could not start its search command (ripgrep launch failed)` | `@vscode/ripgrep` 在 FreeBSD 无原生二进制，其 `rgPath` 指向缺失文件 | `pkg install ripgrep`，`grep`/`glob` 工具会自动回退到系统 `rg`（或设 `DSH_RIPGREP_PATH` 指向你的 `rg`）。代码修复在 `packages/fs/tool-fs-search/src/search-core.ts`。 |
| `bash` / `grep` 落在 `$HOME`（或仓库根）而非任务里设的项目目录 | 本 fork 尚未把任务的"项目目录"字段接进 `session.header.cwd`，命令 cwd 回退到 `process.cwd()`（即 `dsh web` 启动目录） | 显式指定项目：启动加 `DSH_PROJECT_DIR=/项目路径`，或在 rc.d 服务里 `sysrc dsh_web_projectdir="/项目路径"`。`freebsd/dsh-web-run.sh` 启动器会 cd 进去。 |

---

## 14. 已验证项

`node-pty` 原生编译通过；`sharp` 经 WASM 渲染；`pnpm run build` 完整跑通（`tsc -b` + `tsdown` + `vite`）；`dsh web` 在环回地址上以 HTTP 提供 UI。
