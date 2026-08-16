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


> **完整分步安装手册：** 参见 [FREEBSD.md](FREEBSD.md)（前置依赖、`@pnpm/exe.freebsd-x64` 坑、gmake shim、bash 硬依赖、环回围栏、服务/rc.d、git 远端、排错表）。


```sh
git clone https://gitcode.com/skywalk163/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh:freebsd web
```


#### 前置依赖

```sh
pkg install node24 npm-node24 gmake python3 pkgconf bash
```


```sh
npm install -g pnpm@11.7.0
# or, without root:
npm install pnpm@11.7.0 --prefix "$HOME/.pnpm-home"
export PATH="$HOME/.pnpm-home/node_modules/.bin:$PATH"
```




```sh
mkdir -p "$HOME/bin" && ln -sf /usr/local/bin/gmake "$HOME/bin/make"
export PATH="$HOME/bin:$PATH"
```

#### 为什么 FreeBSD 要用 `pnpm dsh:freebsd`



  ```sh
  DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
  ```

  这会以**无约束**方式运行 agent。只在你愿意让 agent 修改该机器时才这样做。

#### 仓库为 FreeBSD 预置了什么




#### 如何访问 Web UI（想对外暴露前必读）



实际影响：


可用的访问方式：

1. **SSH 隧道（推荐）。** 在你的工作机上：
   ```sh
   ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>
   ```
2. **在 FreeBSD 本机上**，直接访问 `http://127.0.0.1:3080` 即可，一切原生可用。


#### 作为服务运行（重启脚本 + rc.d）


- `freebsd/dsh_web.rcd`——rc.d 服务模板。

直接拉起服务（无需 root）：

```sh
sh freebsd/dsh-web-restart.sh restart   # also: stop / start / status
```


```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
sysrc dsh_web_chdir="$(pwd)"     # repo path, auto-filled; run this in the repo
sysrc dsh_web_user=workbuddy     # change if your account is not "workbuddy"
service dsh_web start            # verify
service dsh_web status
```

注意：


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
| 启动时报 `PTY shell exited during startup` / `terminal-bash: ... does not exist` | 未安装 bash（FreeBSD 自带 `/bin/sh` 而非 bash）；`terminal-bash` 后端需要 bash（`PROMPT_COMMAND` + `--noprofile/--norc`） | `pkg install bash`（或 `cd /usr/ports/shells/bash && make install clean`）。该后端不能使用默认的 `/bin/sh`。 |

#### FreeBSD 上的验证结果



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
