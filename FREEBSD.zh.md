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
pkg install -y node24 npm-node24 gmake python3 pkgconf bash
```

| 包 | 作用 |
| --- | --- |
| `node24` | Node.js 24（`engines` 要求 `^22.19.0 \|\| >=24.0.0`） |
| `npm-node24` | 随 Node24 的 npm（FreeBSD 上 npm 是独立包，`node24` 不自带） |
| `gmake` | GNU make。`/usr/bin/make` 是 BSD make，node-gyp 需要 GNU make，第 3 步做 shim |
| `python3` | `node-pty` 编译用（验证 3.11 / 3.12 均可） |
| `pkgconf` | node-gyp / Node 头文件探测 |
| `bash` | **硬依赖**，见第 4 步，FreeBSD 默认不装 |

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

## 9. 运行 Web UI

```sh
DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
```

- `dsh:freebsd` = 普通 `dsh` + `--expose-internals`。FreeBSD 上 HMR 服务必须该 flag，且**不能**经 `NODE_OPTIONS` 传（`node-addon-require-builtin` 只发布 darwin/linux/win32 预编译，FreeBSD 无原生包也无源码兜底）。
- **`DSH_PERMISSION_MODE=danger-full-access` 在 FreeBSD 上是必选项。** harness 不发行 FreeBSD 沙箱后端——confinement 只认识 Linux 的 bwrap/Landlock、macOS 的 Seatbelt、以及 Windows 的 ACL 受限令牌 runner。任何**受限**模式（`read-only` / `workspace-write`）都会**fail-closed** 并拒绝以非隔离方式运行命令。该变量让 agent 以**非隔离**方式运行，这是 FreeBSD 上目前唯一受支持的运作方式。**只在你愿意让 agent 修改的机器上这样跑。**
- ⚠️ **`code` / `mini` 模式恰恰栽在这里。** 它们把持久 PTY bash 会话经由*受沙箱约束的* bash executor 驱动。若某会话**未**处于 `danger-full-access`（你保留着 Web 默认的 `workspace-write`，或存储的 UI 权限预设是 `workspace-write`），每条 `bash`/`ls`/文件命令都会中止并报：
  ```
  Error: sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host;
  refusing to run the command unconfined. This host runs FreeBSD, which this build does not ship a
  sandbox backend for (no bwrap, Landlock, Seatbelt, or Windows ACL runner). Run the consumer
  unconfined by switching it to `danger-full-access`: launch with DSH_PERMISSION_MODE=danger-full-access,
  or pick the danger-full-access permission preset in the UI.
  ```
  该报错**是设计如此（fail-closed），并非崩溃。** 在启动前设 `DSH_PERMISSION_MODE=danger-full-access`（推荐修复），或在 UI 中选 **danger-full-access** 权限预设，该模式即以非隔离方式运行。
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

测试机上 helper 脚本（换成你自己的用户路径）：

- `/home/workbuddy/dsh-web-run.sh`——启动器：设 `DSH_PERMISSION_MODE`、cd 进仓库、`exec pnpm dsh:freebsd web`。
- `/home/workbuddy/dsh-web-restart.sh`——一键控制：`stop | start | restart | status`（默认 `restart`）。

```sh
sh /home/workbuddy/dsh-web-restart.sh restart   # 也可：stop / start / status
```

开机自启（需 root）：

```sh
su - root
cp /home/workbuddy/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
service dsh_web start        # 验证
service dsh_web status
```

注意：

- `pnpm` 要持久化（本机在 `/home/workbuddy/.local/bin/pnpm` v11.7.0），别用 `/tmp/p117` 这类重启会被清的路径。
- rc.d 的 `pidfile` 与日志放在 home（`/home/workbuddy/dsh_web.pid`、`/home/workbuddy/dsh_web.log`）以避开 `/tmp` 清理、重启不丢。
- rc.d 服务以 `workbuddy` 用户运行；装到别处请改 `dsh_web_user`。

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
| `code` / `mini` 模式报 `sandbox mode "..." is requested but no sandbox backend is usable`（`SANDBOX_UNAVAILABLE`） | FreeBSD 无沙箱后端，且会话未处于 `danger-full-access` | **启动前设 `DSH_PERMISSION_MODE=danger-full-access`**（推荐），或在 UI 中选 **danger-full-access** 权限预设。这是设计上的 fail-closed，不是崩溃——见第 9 步。 |
| `crypto.randomUUID is not a function` | 非安全上下文（plain http / 非 localhost） | 经 `http://localhost:3080`（SSH 隧道）访问。 |
| `transport failure for /api/host.listDirectory: HTTP 403` | 环回信任围栏拒绝非 loopback `Host` | 用 SSH 隧道 / `localhost`，别用反代或 LAN IP。 |
| `node-pty` 编译失败 / ETIMEDOUT 拉 Node 头文件 | node-gyp 拉不到头文件 | 保留 `.npmrc` 的 `disturl`；确保 gmake shim 在 `PATH`。 |
| `PTY shell exited during startup` / `terminal-bash: ... does not exist` | 没装 bash（FreeBSD 默认 `/bin/sh`） | `pkg install bash`；该后端不能用默认 sh。 |
| `gen-third-party-notices` 钩子 commit / push 失败 | 上游钩子要 Linux-only 的 claude-agent-sdk | FreeBSD 平台不兼容，与改动无关；`git commit --no-verify` 或 `git -c core.hooksPath=/tmp/nohooks push`。 |

---

## 14. 已验证项

`node-pty` 原生编译通过；`sharp` 经 WASM 渲染；`pnpm run build` 完整跑通（`tsc -b` + `tsdown` + `vite`）；`dsh web` 在环回地址上以 HTTP 提供 UI。
