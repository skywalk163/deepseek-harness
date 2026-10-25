# dsh FreeBSD Port — 产包 / 托管 / 测试 / 提交上游手册

[English](PORTING.md) | 中文
配套交付：`devel/deepseek-harness/`（port 本体）、
`tools/make-port-distfile.sh`（distfile 生产脚本）。
形态决策见 `README.md`。

---

## 1. 在 1.5 上产 distfile

前置条件：仓库 `/home/workbuddy/github/deepseek-harness` 处于**已构建**状态
（`lib/`、`apps/web/dist`、`native/system/packages/freebsd-x64/bin/system.node`
都在）。**不要在构建进行中跑**——`clean` 窗口期会让预检失败（2026-10-17 实测踩到）。

```sh
# 上传并脱离启动（ssh_run.py --file 不传参；脚本无参即自行 detached，
# 默认版本 0.2.1a4；换版本先改脚本里的默认值或本机前台跑
# `sh make-port-distfile.sh 0.2.1a5`）
python tools/ssh_run.py --file dsh-freebsd-port/tools/make-port-distfile.sh

# 跟随日志
python dsh_ssh.py cmd 'tail -f /tmp/mkdist.log' - 60
```

脚本依次做：

1. **preflight** — 检查三处构建产物 + node/curl；打印 node/pnpm 版本。
2. **deploy** — `pnpm --filter @deepseek-ai/dsh deploy --prod <stage>`：
   CLI 的生产依赖闭包（~290 个 workspace 包 + npm 依赖，从 store 硬链）。
   `--prod` 失败会自动退回全量（prod+dev）闭包重试。
3. **fixups** — 前端 dist、freebsd-x64 原生 addon（若 deploy 漏带则从仓库补）、
   LICENSE / THIRD_PARTY_NOTICES.md / `freebsd/dsh-jail-run.c`、清 tsbuildinfo。
4. **冒烟** — 空闲 RAM ≥ 1.5GB 时，以 scratch HOME 在 127.0.0.1:3999 拉起
   `node --expose-internals lib/bin.js web`，要求 90 秒内出现 token 行且
   `GET /?token=...` 返回 **200**（内存不足则大声 SKIP，不阻塞产包）。
5. **tar** — 所有权归一化为 root:wheel，`sha256 -q` 出校验值。
6. **碎片** — `distinfo.fragment`（SHA256+SIZE 两行）和
   `pkg-plist.fragment`（bundle 全文件清单，含特殊条目）。

产物在 `/tmp/dsh-port-dist/`。**把两个 fragment 回填进 port 目录**
（distinfo 再加一行 `TIMESTAMP = $(date +%s)`），然后进入下一步。

## 2. 已知坑（2026-10-17 在 1.5 实测，按踩坑顺序）

1. **stage 必须与 pnpm store 同文件系统**。store 在
   `/home/workbuddy/.local/share/pnpm/store/v11`（zroot/home/workbuddy）；
   stage 放 `/tmp`（zroot/tmp）时跨设备无法硬链，pnpm 会**静默改用
   /tmp/.pnpm-store 并联网重下全部依赖**（npmmirror 超时就直接卡死）。
   所以 `DSH_WORK` 默认在 home 下。
2. **`pnpm deploy` 必须加 `--legacy`**（pnpm 11.28.5 实测）：
   - 默认（新）实现遇 shared lockfile 直接失败，官方建议
     `forceLegacyDeploy: true`；
   - 新实现把 workspace 包解析成绝对 `file:///...`，仓库
     `pnpm-workspace.yaml` 的 `allowBuilds` 键是相对
     `file:packages/...` → 失配 → `strictDepBuilds` 把
     `dsh-subprocess-local` 的 postinstall 变成硬错误
     （ERR_PNPM_IGNORED_BUILDS）。
   legacy 实现两个问题都没有，且仍走 home store 硬链（零联网）。
3. **`deploy --prod` 不装 workspace 包的 peerDependencies**：
   `dsh-app-boot` 把 `@deepseek-ai/cordis-plugin-group`（vendor/group）
   声明为 peer，部署树缺它 → 一启动就
   `ERR_MODULE_NOT_FOUND`。脚本用内嵌 `reconcile.mjs` 从 **workspace
   源码目录**（按 package.json name 扫描，排除 node_modules/.git）补齐
   —— **绝不能从 node_modules 拷贝**：那边有上游删除遗留的悬空
   symlink（cp 报 ENOENT）和 symlink 环（cp -RL 报 cycle 并拷出
   20 层嵌套 node_modules）。
4. **部署树带 `uarch` 文件标志**（pnpm store 自 2026-09-11 起就有，
   硬链继承；live 仓库 node_modules 同样带）。`rm -rf` 对它报
   EPERM（"Operation not permitted"）——属主和 mode 都正常也没用。
   清理前必须 `chflags -R 0`。**对 port 无影响**：tar/cpio 不存 BSD
   fflags，distfile 与 pkg 产物是干净的。
5. **冒烟要 detached + 自记录日志**：SSH 通道一断，前台脚本会被
   SIGPIPE 杀；后台 node 若继承了通道 stdout 还会让 `stdout.read()`
   水远不 EOF（假卡死）。脚本内 node 的重定向已隔离，外层再
   nohup 自脱离。
6. **不要在构建进行中跑**：`clean` 窗口期 `lib/` 会短暂消失，预检
   直接 FATAL（先 `pgrep -fl 'tsc -b|pnpm run build'` 确认空闲）。

## 3. 托管 distfile（GitHub 主 + gitcode 中国镜像）

```sh
VER=0.2.1a4
gh release create freebsd-$VER \
  --repo skywalk163/deepseek-harness \
  --title "FreeBSD runtime bundle $VER" \
  --notes "Prebuilt FreeBSD runtime closure for the devel/deepseek-harness port." \
  /tmp/dsh-port-dist/deepseek-harness-$VER-freebsd-amd64.tar.gz
```

- Makefile 的 `MASTER_SITES` 已按 **GitHub 主源 + gitcode 镜像** 配好，ports 的
  fetch 会按顺序尝试，中国用户自动走快的那个。
- gitcode 是否镜像 release **附件**（不只是 tag 归档）需实测：上传后
  `curl -sI https://gitcode.com/skywalk163/deepseek-harness/releases/download/freebsd-0.2.1a4/deepseek-harness-0.2.1a4-freebsd-amd64.tar.gz`
  应返回 200/302。若不镜像附件，就把 gitcode 那行 MASTER_SITES 去掉（或改为
  指向 gitcode 的源码归档 + 另行托管 bundle）。
- port 进树后，`distfiles.freebsd.org` 会自动缓存 distfile，最终用户（含中国）
  实际从 FreeBSD 官方镜像下载，GitHub 只是冷启动来源。

## 4. 本机验证（1.5 自带 /usr/ports）

```sh
# port 目录上传到 1.5: /tmp/dsh-port/devel/deepseek-harness
# distfile 放到 DISTDIR（端口构建前 make 会校验 checksum）
DISTDIR=/tmp/dsh-port-dist

make -C /tmp/dsh-port/devel/deepseek-harness DISTDIR=$DISTDIR checksum   # 校验 distinfo
make -C /tmp/dsh-port/devel/deepseek-harness DISTDIR=$DISTDIR stage      # 全量 stage
make -C /tmp/dsh-port/devel/deepseek-harness DISTDIR=$DISTDIR check-plist
```

关注点：

- `make stage` 会产出 `${WRKDIR}/stage`——拿它和 `pkg-plist.fragment` 对账，
  确认 `USE_RC_SUBR` 自动装了 `etc/rc.d/dsh_web` 且 plist 无需手写该行
  （若报 plist 缺项/重复，按报错增删 `etc/rc.d/dsh_web` 一行即可）。
- 真机安装验证（root）：
  ```sh
  make -C ... install
  /usr/local/bin/dsh --help                  # wrapper + --expose-internals
  /usr/local/bin/dsh web --port 3999 &       # 冒烟：token URL 200
  ls -l /usr/local/libexec/dsh-jail-run      # 应为 4755 root:wheel
  sysrc dsh_web_enable=YES && service dsh_web start   # rc.d + token 回显
  service dsh_web status
  ```
- jail 助手单独验：`/usr/local/libexec/dsh-jail-run --workspace /tmp --mode read-only -- /bin/echo ok`
  （在仓库里跑 `sh freebsd/run-verify.sh` 是 10/10 的完整判据，port 场景至少
  要确认 setuid 位和路径解析）。

## 5. 提交到 FreeBSD ports（Bugzilla）

```sh
cd /tmp/dsh-port/devel
tar czf ~/deepseek-harness-port.tar.gz deepseek-harness
# 或 git 格式：在 ports git clone 里 commit 后 format-patch
```

提交要点（写进 PR 描述，预答 reviewer）：

1. **bundled node_modules 的正当性**：dsh 是 pnpm monorepo（~290 workspace
   包），完整依赖闭包不在 ports 树；源码构建需 30+ 分钟 / 2–4GB RAM，
   poudriere 集群不接受。distfile 内含 `THIRD_PARTY_NOTICES.md`，
   `LICENSE=MIT` + `LICENSE_FILE`。
2. **setuid 二进制**：`libexec/dsh-jail-run`（4755 root:wheel）是 FreeBSD
   jail 沙箱后端的必要部件，代码在 distfile 内（`freebsd/dsh-jail-run.c`），
   安全模型见文件头注释（jail 内降权为调用者 uid、workspace 路径校验）。
3. **category=devel**：AI 编程 agent 工具链；若 portmgr 建议换类再 repocopy。
4. **版本**：`DISTVERSION=0.2.1a4` → 框架导出 `PORTVERSION=0.2.1.a4`
   （Porter's Handbook 预发布版规则：首字母 + 点，后续数字不加点）。
5. **ONLY_FOR_ARCHS=amd64**：distfile 内含 amd64 原生 addon；aarch64 包
   已在路线图上（见 §5）。
6. **loopback 围栏**：Web UI 只信任 loopback（安全设计），pkg-message 已
   写明 SSH 隧道用法——这不是 bug，是预期行为。

## 6. 后续路线

- **aarch64**：在 aarch64 FreeBSD 机上跑同一脚本产
  `deepseek-harness-<ver>-freebsd-aarch64.tar.gz`，Makefile 改
  `DISTFILES= ${PORTNAME}-${DISTVERSION}-freebsd-${ARCH}.tar.gz` 并去掉
  `ONLY_FOR_ARCHS`。
- **CI 自动化**：gitea（1.5）加一个 workflow，tag 推送时自动跑
  `make-port-distfile.sh` 并上传 release——消除"在 1.5 手跑"这一步。
- **版本升级**：fork 发新版 → 重跑脚本 → 更新 distinfo + DISTVERSION →
  三远端推送 → 更新 PR。`fork-after-upstream-*` 基线 tag 即版本锚点。
- **考虑拆 port**：若 portmgr 对体积有异议，可把 jail 助手拆成独立小 port
  （`devel/dsh-jail-run`），主 port 改为依赖它。

## 7. 本机 port 构建 / 校验实战踩坑（2026-10-18）

port 本体与 distfile 跑通后，在 1.5 自带 `/usr/ports` 做本机校验时踩的坑。完整操作存档见
`TASK-LOG-2026-10-18.md`，这里只列判据与结论。

1. **`make install` 必须 root**：ports 惯例会 `su` 切 root，普通用户直接跑报 `su: Sorry`。
   用 `ssh_run.py --sudo` 在远端以 root 执行。
2. **`pkg-plist` 不能写 `#` 注释行**：`check-plist` 不认，直接报错 → 删除。
3. **不要手写 `@stopdaemon dsh_web`**：`USE_RC_SUBR=dsh_web` 框架自动注入该关键字，
   手写反而重复导致 check-plist 失败。
4. **`stopdaemon` 关键字在本机 ports 树缺失**：测试环境若缺
   `/usr/ports/Keywords/stopdaemon.ucl`，`make install` 报
   `unknown keyword stopdaemon`。正式 ports 树自带；测试机补一个只含
   `post-install`（调 `service %@ onestop`）的 `stopdaemon.ucl` 即可
   —— **别带 `actions: [file, dir]`**，否则 pkg 把 `dsh_web` 当文件路径 stat 而失败。
5. **验证链路（绿）**：`make checksum` → `make stage` →
   `make check-plist`（"No pkg-plist issues found"）→
   `make install PREFIX=/tmp/dshtest`（root）落地 `bin/dsh` / `etc/rc.d/dsh_web`
   / setuid `libexec/dsh-jail-run`（4755 root:wheel），`dsh --help` 正常。
   0.88 机器接续步骤见 `TASK-LOG-2026-10-18.md` §6。
6. **跨机传 port 文件别用 4.8MB heredoc 脚本**：SSH 通道会 PipeTimeout 超时。
   改用 `tools/port_push.py`（`sftp.put()` 直传真实文件 + `mkdir -p` 建目录）。
   （`install-port-files.sh` 是过时传输产物，已不进仓库。）
