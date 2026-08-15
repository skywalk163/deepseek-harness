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

DeepSeek Harness 可以在 FreeBSD 上运行（已在 FreeBSD 14.3-RELEASE amd64 +
Node 24 上验证）。所有 FreeBSD 相关的适配都已固化在 `pnpm-workspace.yaml` 中，
克隆后按标准流程即可：

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh:freebsd web
```

Web UI 监听 `http://127.0.0.1:3080`。从其他机器访问需做端口转发：
`ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>`。

#### 前置依赖

```sh
pkg install node24 npm-node24 gmake python3 pkgconf
```

本仓库通过 `packageManager` 钉住 `pnpm@11.7.0`，而 FreeBSD ports 里的 `pnpm`
可能偏旧。请安装钉住的版本（root 全局安装，或装到用户目录）：

```sh
npm install -g pnpm@11.7.0
# 无 root 权限时：
npm install pnpm@11.7.0 --prefix "$HOME/.pnpm-home"
export PATH="$HOME/.pnpm-home/node_modules/.bin:$PATH"
```

通常用的 `corepack enable` 在非 root 下会因为要往 `/usr/local/bin` 写 shim 而
报 `EACCES`。

`pnpm install` 期间 `node-pty` 会编译原生模块，而 `node-gyp` 要求名为 `make`
的 GNU make——FreeBSD 的 `/usr/bin/make` 是 BSD make。需要加一个 shim 到 `PATH`
前面：

```sh
mkdir -p "$HOME/bin" && ln -sf /usr/local/bin/gmake "$HOME/bin/make"
export PATH="$HOME/bin:$PATH"
```

#### 为什么 FreeBSD 要用 `pnpm dsh:freebsd`

`dsh:freebsd` 就是普通的 `dsh` 入口再加 `--expose-internals`，另外还必须设置
`DSH_PERMISSION_MODE`：

- **`--expose-internals` 在 FreeBSD 上是硬性必需。** loader 获取 Node 内部 ESM
  loader 有两条路：这个 flag，或者 `node-addon-require-builtin` 原生插件。而该
  插件只发布了 darwin/linux/win32 的预编译包——没有
  `node-addon-require-builtin-freebsd-x64`，也没有源码编译兜底——所以在 FreeBSD
  上只剩这个 flag。不加它，HMR 服务（`web` 这类长驻形态会无条件挂载）会直接以
  `--expose-internals is required for HMR service` 中止启动。这个 flag 也不能通过
  `NODE_OPTIONS` 传入，Node 会拒绝。
- **沙箱没有 FreeBSD 后端。** 隔离只支持 Linux（`bwrap`/`landlock`）、macOS
  （`seatbelt`）和 Windows ACL，所以在 FreeBSD 上会 fail-closed 并中断启动。启动
  时需要：

  ```sh
  DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
  ```

  这会让 agent **在无隔离状态下运行**。请只在你愿意让 agent 直接改动的机器上这么做。

#### 仓库为 FreeBSD 预置了什么

全部位于 `pnpm-workspace.yaml`——pnpm v11 已不再读取 `package.json` 的 `pnpm`
字段，`.npmrc` 也只读 auth/registry 类配置：

- **`supportedArchitectures`**（`os: freebsd`，`cpu` 同时含 `x64` 与 `wasm32`）。
  `sharp` 没有发布 FreeBSD 原生二进制（`@img/sharp-freebsd-x64` 不存在），所以
  它的 WASM 路线——`@img/sharp-freebsd-wasm32` 转发到 `@img/sharp-wasm32`——是
  唯一可用的图像后端。该包声明了 `cpu: wasm32`，因此在 x64 主机上如果不显式列出
  `wasm32`，会被 pnpm 的平台过滤跳过。也就是说图像处理走 WASM，比原生构建慢。
  漏掉这项，启动时会报
  `Could not load the "sharp" module using the freebsd-x64 runtime`。
- **`shamefullyHoist: true`**。运行时 loader 通过动态
  `import('@deepseek-ai/dsh-client-ui-*')` 解析插件。在 pnpm 的隔离式布局下，这些
  工作区包不会出现在顶层 `node_modules`，动态导入会以 `ERR_MODULE_NOT_FOUND` 失败。
- **针对 `sharp` 的 `packageExtensions`**——与 `supportedArchitectures` 作用重叠，
  保留作为对两个 WASM 运行时包的显式声明。

`.npmrc` 另外把 `registry` 和 `disturl` 指向了 npmmirror 镜像，让 FreeBSD 平台
tarball 和 `node-pty` 的 Node headers 在中国大陆网络下能稳定下载。若想用默认源，
删掉这两行即可。

#### FreeBSD 上的验证结果

`node-pty` 原生编译通过、`sharp` 经 WASM 成功渲染、`pnpm run build` 完整跑通
（`tsc -b` + `tsdown` + `vite`）、`dsh web` 正常通过 HTTP 提供 UI。

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
