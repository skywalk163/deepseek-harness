# dsh FreeBSD Port — 交付说明

把 FreeBSD 自维护版 deepseek-harness（dsh）打包成正式 FreeBSD port，让用户
`make install` / `pkg install deepseek-harness` 即可使用。

## 形态决策（先说清楚，避免误会）

**port 目录里只有"安装程序"（Makefile/pkg-plist/rc.d/wrapper），没有任何源码**；
distfile（自包含运行时包）在 `make fetch` 时从 GitHub 下载，gitcode 作中国镜像。
这正是您要的模型。但** distfile 不是源码包，而是预构建的运行时闭包**，原因：

1. FreeBSD ports 的**构建阶段禁止联网**——依赖要么来自 ports 树，要么打进
   distfile。dsh 是 ~290 个 workspace 包的 pnpm monorepo，~1500 个 npm 依赖
   （含 node-pty 原生补丁、sharp wasm、各平台原生包）在 ports 树里几乎不存在。
2. 现场源码构建要 `pnpm install` + `pnpm run build`：**30+ 分钟、峰值 2–4GB
   内存**。poudriere 集群构建器（8GB 内存、严格时限）会直接拒收，普通用户
   `make install` 等半小时也不是体验。
3. 先例：OnlyOffice、VS Code server 等复杂应用在 ports 里同样是"下载预构建
   产物 + 安装"的形态。

port 里唯一编译的东西是 `freebsd/dsh-jail-run.c`（setuid jail 助手，~600 行 C，
只用 jail(2)，无外部依赖）。

## 文件布局

```
dsh-freebsd-port/
├── README.md                        本文件
├── PORTING.md                       产包/托管/测试/提交上游完整手册
├── tools/
│   └── make-port-distfile.sh        在 1.5 上产 distfile（deploy+冒烟+tar+碎片）
└── devel/deepseek-harness/          port 本体（ports 树格式）
    ├── Makefile                     DISTVERSION 0.2.1a4，GitHub/gitcode 双源
    ├── distinfo                     ← distfile 跑完后回填
    ├── pkg-descr
    ├── pkg-message.in               安装后说明（loopback 围栏/服务/jail）
    ├── pkg-plist                    ← distfile 跑完后回填
    └── files/
        ├── dsh.in                   /usr/local/bin/dsh wrapper（--expose-internals）
        └── dsh_web.in               rc.d 服务（吸收 1.5/0.88 全部实战教训）
```

## 状态

- [x] 侦察：运行时闭包 = CLI 的 287 包生产依赖图（可达性分析证实 agent 核心栈全在内）
- [x] port 骨架（Makefiles/rc.d/wrapper/pkg-message）
- [x] distfile 生产脚本（pnpm deploy --legacy --prod + 开机冒烟 + tar + 碎片输出）
- [x] 1.5 实跑验证 deploy 路线：`--legacy` 绕开 shared-lockfile 缺陷 + allowBuilds 失配；
      home store 硬链零联网；node-pty 编译产物/flock addon/web dist 全部在位
- [x] 发现并修复 peer 依赖缺失：dsh-app-boot 等把 cordis-plugin-group 声明为
      peerDependencies，`pnpm deploy --prod` 不装——脚本用 node 从 workspace
      源码目录（非 node_modules  symlink，那边有悬空链和环）补齐缺失包
- [x] **修复 distfile 不可移植**：deploy 树里 workspace 包是"指向构建机源码仓库的
      符号链接"，拷到别机悬空 → `dsh` 启动 `ERR_MODULE_NOT_FOUND`；脚本加"解引用"
      步骤后重跑，distfile（62,207,174 B）在 1.5 上 `make install`+`dsh --help` 全绿
- [x] 最终跑：冒烟绿 → **distinfo/pkg-plist 已回填**（SHA256 + SIZE + TIMESTAMP 在 distinfo）
- [x] 1.5 真机 `make checksum/stage/check-plist` + `make install PREFIX=/tmp/dshtest` 实测全绿
      （bin/dsh、etc/rc.d/dsh_web、setuid libexec/dsh-jail-run 均正确落地，
      check-plist 报 "No pkg-plist issues found"）
- [x] **本文档已归档到 `TASK-LOG-2026-10-18.md`**，并 push 到 gitea `skywalk/deepseek-harness`
      （作为 `dsh-freebsd-port/` 子目录，0.88 机器 `git fetch` 即可接续）
- [ ] GitHub release 托管 + gitcode 镜像（distfile 已生成但未上传，见 PORTING.md §3）
- [ ] PORTING.md 中的提交清单（Bugzilla 提交）
