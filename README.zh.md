# DeepSeek Harness

[English](README.md) | 中文

DeepSeek Harness（`dsh`）是由 [DeepSeek AI](https://deepseek.com) 开发的开源 agent harness（智能体框架）。

它采用**一切皆插件**的架构，并由 [Cordis](https://github.com/cordiverse/cordis) 驱动，其设计参见论文 [_A Programming Paradigm for Spatiotemporal Composability_](https://github.com/cordiverse/paper)。

## 开发者预览

DeepSeek Harness 目前处于 _开发者预览_ 阶段，正在快速迭代。**未来将出现破坏兼容性的变更。**

## 运行

### 通过 `npm` 运行

安装 `Node.js`，然后运行：

```sh
npx @deepseek-ai/dsh web
```

该命令会启动 Web UI，默认地址为 `http://127.0.0.1:3080`。详见 [Web UI 指南](docs/user/guide/index.md)。

### 从源码运行

如需从仓库源码运行：

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```


### 在 FreeBSD 上从源码运行

> **FreeBSD 请用本 fork——尚未合并到上游。** FreeBSD 移植（修复 `process-inspector` 的 ps 语法、`terminal-bash` 默认 shell、`crypto.randomUUID` polyfill，以及仅环回地址的信任围栏）**维护在本仓库**，并且**尚未合并进上游 `deepseek-ai/deepseek-harness`**。在合并落地前，请克隆**本仓库**而非上游，否则会缺少 FreeBSD 修复。
> 镜像：`https://github.com/skywalk163/deepseek-harness.git`

> **完整分步安装手册：** 参见 [FREEBSD.zh.md](FREEBSD.zh.md)（前置依赖、`@pnpm/exe.freebsd-x64` 坑、gmake shim、bash 硬依赖、环回围栏、服务/rc.d、git 远端、排错表）。

DeepSeek Harness 可以在 FreeBSD 上运行（已在 FreeBSD 14.3-RELEASE amd64 + Node 24
上验证）。所有 FreeBSD 相关的适配都已固化在 `pnpm-workspace.yaml` 中，clone 之后走标准流程即可：

```sh
git clone https://gitcode.com/skywalk163/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh:freebsd web
```

Web UI 监听在 `http://127.0.0.1:3080`，并且**只响应环回地址**（见下方
"如何访问 Web UI"——这是硬性安全围栏，不是配置项）。若想从别的机器打开，请用 SSH 隧道：
`ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>`，然后浏览器访问
`http://localhost:3080`。

#### 前置依赖

```sh
pkg install node24 npm-node24 gmake python3 pkgconf bash
```

本仓库通过 `packageManager` 钉死 `pnpm@11.7.0`，而 FreeBSD ports 里的 `pnpm`
可能更旧。请安装钉死的版本，要么以 root 全局安装，要么装到自己家目录：

```sh
npm install -g pnpm@11.7.0
# 或者不用 root：
npm install pnpm@11.7.0 --prefix "$HOME/.pnpm-home"
export PATH="$HOME/.pnpm-home/node_modules/.bin:$PATH"
```

`corepack enable` 是常见替代方案，但非 root 用户会因向 `/usr/local/bin` 写 shim
而报 `EACCES`。

`bash` 是**硬依赖**（即便它**不**属于 FreeBSD 默认安装，base 交互 shell 是
`/bin/sh`，一个 ash 衍生版）。`terminal-bash` 后端——被 `code` 和 `mini` agent
模式使用——依赖 bash 专有行为：`PROMPT_COMMAND` 输出每命令结束的 OSC `133;D;`
标记，harness 据此判断命令结束与退出码；默认 shell 参数 `--noprofile --norc -i`
也是 bash 专有。base 的 `/bin/sh` 无法替代；若缺 bash，服务会报
`PTY shell exited during startup`（或在该后端自带校验下给出清晰的
`terminal-bash: ... does not exist` 提示）。若你的镜像漏装了 bash，从 ports 装：
`cd /usr/ports/shells/bash && make install clean`。仓库已在
`packages/terminal/terminal-bash/src/config.ts` 加了校验：shellPath 不存在 / 非
bash会直接报清晰错误，而不再静默回退到不存在的路径。

`node-pty` 在 `pnpm install` 期间会编译原生插件，而 `node-gyp` 需要把 GNU make
当作 `make` 调用——FreeBSD 的 `/usr/bin/make` 是 BSD make。在 `PATH` 前面放一个 shim：

```sh
mkdir -p "$HOME/bin" && ln -sf /usr/local/bin/gmake "$HOME/bin/make"
export PATH="$HOME/bin:$PATH"
```

#### 为什么 FreeBSD 要用 `pnpm dsh:freebsd`

`dsh:freebsd` 就是普通的 `dsh` 入口再加 `--expose-internals`，另外还必须设置
`DSH_PERMISSION_MODE`：

- **`--expose-internals` 在 FreeBSD 上是硬性必需。** loader 获取 Node 内部 ESM
  loader 要么靠这个 flag，要么靠 `node-addon-require-builtin` 原生插件。该插件只发布
  darwin/linux/win32 预编译包——既没有 `node-addon-require-builtin-freebsd-x64`，
  也没有源码编译兜底——所以在 FreeBSD 上这个 flag 是唯一路径。缺少它时，`web` 这类
  常驻面无条件挂载的 HMR 服务会中止启动并报告
  `--expose-internals is required for HMR service`。该 flag 不能放进 `NODE_OPTIONS`，
  Node 会在那里拒绝它。
- **沙箱没有 FreeBSD 后端。** 隔离只支持 Linux（`bwrap`/`landlock`）、macOS
  （`seatbelt`）和 Windows ACL，所以在 FreeBSD 上会 fail-closed 并中断启动。启动方式：

  ```sh
  DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
  ```

  这会以**无约束**方式运行 agent。只在你愿意让 agent 修改该机器时才这样做。

#### 仓库为 FreeBSD 预置了什么

全部位于 `pnpm-workspace.yaml`——pnpm v11 不再读取 `package.json` 的 `pnpm` 字段，
也只从 `.npmrc` 读取 auth/registry 相关的键：

- **`supportedArchitectures`**（`os: freebsd`，`cpu` 同时含 `x64` 与 `wasm32`）。
  `sharp` 没有发布 FreeBSD 原生二进制（`@img/sharp-freebsd-x64` 不存在），所以
  它的 WASM 路线——`@img/sharp-freebsd-wasm32` 转发到 `@img/sharp-wasm32`——是
  唯一可用的图像后端。该包声明 `cpu: wasm32`，因此若 `wasm32` 未列入，pnpm 的平台
  过滤会在 x64 主机上跳过它。图像处理因此走 WASM，比原生构建慢。漏掉这项会在启动时报
  `Could not load the "sharp" module using the freebsd-x64 runtime`。
- **`shamefullyHoist: true`**。运行时 loader 通过动态
  `import('@deepseek-ai/dsh-client-ui-*')` 解析插件。在 pnpm 的隔离布局下，这些
  工作区包不会出现在顶层 `node_modules`，导入会失败并报告 `ERR_MODULE_NOT_FOUND`。
- **`sharp` 的 `packageExtensions`**——与 `supportedArchitectures` 冗余，保留为对两个
  WASM 运行时包的显式声明。

`.npmrc` 另外把 `registry` 和 `disturl` 指向了 npmmirror 镜像，让 FreeBSD 平台
tarball 与 `node-pty` 的 Node headers 下载在大陆更可靠。删掉这两行即可改用默认源。

#### 如何访问 Web UI（想对外暴露前必读）

> **不能通过 nginx / Caddy / Apache 或任何反向代理访问，也不能直接通过 LAN IP 或
> 公网域名访问。** 它只在环回地址（`localhost` / `127.0.0.1`）下可用。

harness 把所有 host 侧的文件系统 RPC——包括"选择工作区目录"选择器
（`host.listDirectory`）——都放在一道**仅限环回的信任围栏**之后
（`packages/client/connection/src/rpc-host.ts`、`api-request-trust.ts`）。请求的
`Host` 头若不是被认可的环回名，会在到达处理器之前被拒并返回 `HTTP 403`。该检查
只接受 `localhost`、`[::1]` 和 `127.x.x.x`。

实际影响：

- **反向代理 / LAN IP / 公网域名 → `403`。** 即使 nginx 完美转发，浏览器发出的
  `Host` 也是 `<lan-ip>:3080`（或你的域名）。围栏会拒绝它，于是第一个文件操作——
  选择工作区目录——就会失败并报
  `transport failure for /api/host.listDirectory: HTTP 403`。普通反向代理会保留
  客户端的 `Host`，因此无济于事；把 `Host`/`Origin` 改写成 `localhost:3080` 既脆弱
  又**不**推荐给新手。
- **直接用 `http://<lan-ip>:3080` 打开 → 同样被拦**，原因相同；此外浏览器在非安全
  （非 localhost、非 HTTPS）上下文会禁用 `crypto.randomUUID()`。（仓库已附带 polyfill
  来缓解这个报错，但文件操作的真正拦路虎是 403 围栏。）

可用的访问方式：

1. **SSH 隧道（推荐）。** 在你的工作机上：
   ```sh
   ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>
   ```
   然后打开 `http://localhost:3080`。这同时给出环回 `Host`（无 403）**和**安全上下文
   （原生 `crypto.randomUUID` 可用）——两个问题一次性消失。
2. **在 FreeBSD 本机上**，直接访问 `http://127.0.0.1:3080` 即可，一切原生可用。

如果你确实需要脱离本机访问，请让浏览器看到的是 `localhost`（隧道或 VPN），而不是
保留客户端 `Host` 的反向代理。

#### 作为服务运行（重启脚本 + rc.d）

辅助脚本现在**随仓库一起提供**，位于 `freebsd/` 子目录下，所有路径都相对于脚本自身
所在位置解析，因此无论仓库 clone 到哪里都能直接用（无需改路径）：

- `freebsd/dsh-web-run.sh`——启动器：设置 `DSH_PERMISSION_MODE`、进入仓库根目录、
  `exec` `pnpm dsh:freebsd web`。
- `freebsd/dsh-web-restart.sh`——一键控制：`stop | start | restart | status`
  （默认 `restart`）。
- `freebsd/dsh_web.rcd`——rc.d 服务模板。

直接拉起服务（无需 root）：

```sh
sh freebsd/dsh-web-restart.sh restart   # 也可：stop / start / status
```

如需开机自启，复制 rc.d 模板并指向本仓库即可。`$(pwd)` 会自动填入路径——在仓库根目录
下执行：

```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
sysrc dsh_web_chdir="$(pwd)"        # 仓库路径，自动填入；在仓库内执行本行
sysrc dsh_web_user=workbuddy        # 若你的账号不是 workbuddy 请改掉
service dsh_web start               # 验证
service dsh_web status
```

注意：

- `pnpm` 从 `PATH` 中解析（按上文 `npm install -g pnpm@11.7.0` 安装即可）。**不要**
  依赖 `/tmp/p117` 这类路径——重启会清空 `/tmp`，服务将启动失败。
- `pidfile` 与日志写在**仓库内部**（`/<仓库>/dsh_web.pid`、`<仓库>/dsh_web.log`），
  能熬过重启与 `/tmp` 清理，并随仓库一起移动。
- rc.d 服务以你设置的 `dsh_web_user` 运行；该用户必须拥有仓库目录，才能写 pidfile/日志
  并读取 `node_modules`。

#### 排错 / FreeBSD 已知踩坑

| 现象 | 原因 | 解决办法 |
| --- | --- | --- |
| `Could not load the "sharp" module using the freebsd-x64 runtime` | `sharp` 无 FreeBSD 原生二进制；WASM 路线未装 | 保留 `pnpm-workspace.yaml` 中的 `supportedArchitectures`（`os: freebsd`，`cpu` 含 `wasm32`）与 `sharp` 的 `packageExtensions`。不要删。 |
| `@deepseek-ai/dsh-client-ui-*` 报 `ERR_MODULE_NOT_FOUND` | 工作区插件未被提升 | 保留 `pnpm-workspace.yaml` 中的 `shamefullyHoist: true`。 |
| `--expose-internals is required for HMR service` | 原生插件路线在 FreeBSD 不可用 | 使用 `dsh:freebsd` 脚本（它会加 `--expose-internals`）。该 flag 不能放进 `NODE_OPTIONS`。 |
| 启动中止 / 沙箱 fail-closed | FreeBSD 无沙箱后端 | 以 `DSH_PERMISSION_MODE=danger-full-access` 启动（agent 无约束运行）。 |
| 选目录时 `crypto.randomUUID is not a function` | 非安全上下文（plain http、非 localhost） | 通过 `http://localhost:3080`（SSH 隧道）访问。仓库已含 polyfill，但仍建议用 localhost。 |
| `transport failure for /api/host.listDirectory: HTTP 403` | 环回信任围栏拒绝非环回 `Host` | 用 SSH 隧道 / `localhost` 访问（见"如何访问 Web UI"）。**不要**用反向代理或 LAN IP。 |
| `node-pty` 编译失败 / 下载 Node headers 时 ETIMEDOUT | `node-gyp` 取不到 headers | 保留 `.npmrc` 中的 `disturl=https://registry.npmmirror.com/-/binary/node`（或用就近镜像）；确保 `gmake` shim 在 `PATH` 上。 |
| `pnpm` 版本不对 / 依赖解析异常 | 版本不匹配 | 严格使用 `pnpm@11.7.0`（仓库 `packageManager`）。 |
| 提交/推送时 `gen-third-party-notices` 钩子失败 | 上游钩子依赖 `@anthropic-ai/claude-agent-sdk-linux-x64`（仅 Linux 构建） | FreeBSD 平台不兼容，与你的改动无关。绕过：`git commit --no-verify` 或 `git -c core.hooksPath=/tmp/nohooks push`。只要没新增依赖，内容安全。 |

#### FreeBSD 上的验证结果

`node-pty` 原生编译通过、`sharp` 经 WASM 成功渲染、`pnpm run build` 完整跑通
（`tsc -b` + `tsdown` + `vite`）、`dsh web` 正常通过 HTTP 在环回地址上提供 UI。


## 社区与支持

- 欢迎通过 [GitHub Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions) 提交反馈或 bug 报告。
- 为你的插件仓库添加 [`dsh-plugin`](https://github.com/topics/dsh-plugin) 话题，便于被发现。
- 欢迎加入 DeepSeek Harness 企微群：扫码添加企微小助手并填写入群问卷，完成后小助手会邀请你入群。

<table>
  <thead>
    <tr>
      <th align="center">企微小助手</th>
      <th align="center">入群问卷</th>
      <th align="center">微信公众号</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><img src="assets/community-wecom-assistant.png" alt="DeepSeek Harness 企微小助手二维码" width="180" height="180"></td>
      <td align="center"><a href="https://trtgsjkv6r.feishu.cn/share/base/form/shrcnIt5twSVdLGD52KJBckGCgg"><img src="assets/community-wecom-survey.png" alt="DeepSeek Harness 入群问卷二维码" width="180" height="180"></a></td>
      <td align="center"><img src="assets/community-wechat-official-account.png" alt="DeepSeek Harness 团队微信公众号二维码" width="180" height="180"></td>
    </tr>
  </tbody>
</table>

## 参与贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 开发

请先阅读[开发指南](docs/development.md)与[架构文档](docs/architecture.md)。

面向 agent：请遵循 [AGENTS.md](AGENTS.md)。

## 许可证

[MIT](LICENSE)

第三方依赖及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
