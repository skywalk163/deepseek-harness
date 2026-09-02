# Agent Note: FreeBSD 沙箱档：boxrun jail runner

Status: implemented

[English](2026-08-16-freebsd-boxrun-jail-sandbox.md) | 中文

## 问题

最初的[沙箱决策](2026-07-06-sandbox.zh.md)将 `PLATFORM_CHAINS.freebsd` 留空，因此 FreeBSD 没有隔离后端，任何受限模式都会以 `SANDBOX_UNAVAILABLE` fail-closed——[FreeBSD 手册](../../../../FREEBSD.md) 只能靠 `DSH_PERMISSION_MODE=danger-full-access` 非隔离运行。FreeBSD 没有 bwrap、Landlock、Seatbelt 或 Windows 受限令牌 runner；jail(8) 是原生答案，但创建 jail 需要 root，而服务以非特权用户运行。该档必须约束两种文件效果模式——`read-only`（无可写根目录）与 `workspace-write`（工作区根目录 + 后端定义的临时区域）——并与 Linux 的 bwrap profile 保持对齐，包括把工作区作为命令的工作目录。

## 决策

采用 **boxrun**（[`sysutils/boxrun`](https://gitlab.com/tgasiba/boxrun)，MIT，单文件 C 程序）作为 `freebsd` 档：一个基于 jails + nullfs 挂载 + procctl 加固的 bwrap 等价物，且以 **setuid-root**（`-m 4755`）安装——这正是让非特权服务用户能创建 jail 的原因；boxrun 在执行受限命令前会把权限降回调用者身份。其 CLI 与 bwrap 对齐（`--ro-bind`/`--rw-bind`/`--tmpfs`/`--dev`/`--proc`/`--all`），因此 provider 的集成方式与 seatbelt 档完全一致：唯一候选不探测直接选中，`STATIC_ENFORCEMENT.full`（nullfs 只读挂载从构造上就管控了所有承诺的写效果），denial 方言 `read-only file system`（EROFS，与 bwrap 相同），runner 失败规则基于 `boxrun: ` err(3) 前缀的签名式匹配。

Profile（`boxrunProfileArgs`）把模式映射为挂载：`--all`（系统 + `/usr/local` + `/etc` + `/var` + 全部库目录，只读）、`--dev`（ruleset-4 devfs）、`--proc`、两种模式下 `/home` 都只读（保证 `~/.gitconfig`/`~/.npmrc` 的读取与 bwrap 的只读全树挂载一致）、`workspace-write` 追加 `--tmpfs /tmp` 与工作区根目录的 `--rw-bind`（在只读 `/home` 之上做 nullfs 叠加，与 bwrap 在只读 `/` 之上绑定工作区同构）、`read-only` 保持 `/tmp` 与工作区只读。三个 boxrun 默认值被钉死以保证对齐：`--net`（网络仍在沙箱词汇之外，与所有其他后端一致）、`--inherit-env`（boxrun 默认的 `--clearenv` 会清掉 PATH/HOME 和终端的 `PROMPT_COMMAND` 标记）、`--chdir <工作区>`（boxrun 默认的 `/` 会丢掉 harness 的工作目录）。

两个上游缺陷由仓库补丁 [`patches/boxrun-dsh.patch`](../../../../patches/boxrun-dsh.patch) 承载：boxrun 0.4.3 在 jail 内硬编码 `chdir("/")`（补丁新增 `--chdir DIR`）；并且即使不用任何 `--limit-*` flag，在 `kern.racct.enable=0` 时也拒绝运行（补丁把该硬检查改为警告；`--limit-*` 仍通过 `apply_rctl_rule` fail-closed）。racct 警告与致命的 `boxrun: ` 前缀相同，因此 runner 失败规则把它作为 `informationalLines` 精确行排除（`BOXRUN_RCTL_WARNING`）——否则在 racct 关闭的机器上，任何非零退出的命令都会被误判为 runner 失败。runner 解析到 `/usr/local/sbin/boxrun`（不在普通用户 PATH 上），带 PATH 兜底。工作区根目录为 `/` 时无法绑定（boxrun 禁止挂载 `/`），profile 会省略该绑定；`--chdir /` 即从 jail 根目录开始，这正是该工作区自身的语义。

## 备选方案

- **自研原生 jail runner**（用 C 封装 `jail(8)` + `mount_nullfs`，仿 landlock-run launcher）：完全可控，但要重造 boxrun 已有的全部轮子——挂载顺序、devfs ruleset、权限降级、孤儿回收、死亡信号、崩溃清理——且安全面更大。boxrun 是 MIT、单文件、FreeBSD 官方 port（`sysutils/boxrun`）；我们只额外携带两行 `--chdir`/racct 补丁。
- **Capsicum（`cap_enter`/`cap_rights_limit`）原生封装**：能力模式限制的是已打开的文件描述符而非路径——对任意 `bash -c` 无法表达「只读文件系统 + 可写工作区」，除非按路径逐条授权 FD，且需要被约束程序配合。语义不匹配，否决。
- **每次命令 ZFS snapshot + clone**：隔离强但太重（每次受限运行都要 snapshot/clone），仅限 ZFS，且每次运行都要 root 而非只在安装时。
- **`fusefs-sandboxfs`**：用户态 FUSE，无 jail 加固——比内核 jail 慢且弱。
- **纯 chroot**：无进程/网络隔离，root 可轻易逃逸；不是硬边界，否决。

## 后果

FreeBSD 现在在默认 `workspace-write` 下运行完整的沙箱词汇表，无需任何环境变量覆盖：`bash` 一次性命令与持久 PTY 终端都经 boxrun jail 生成（boxrun 的 `PROC_PDEATHSIG_CTL` 与 `PROC_REAP_KILL` 对应 bwrap 的 `--die-with-parent` 生命周期，且 FreeBSD process-inspector 本就能杀掉 jail 内的进程树）。fail-closed 得以保留：boxrun 缺失、非 setuid 或损坏时，在 spawn/run 阶段抛 `SANDBOX_UNAVAILABLE`，绝不静默非隔离执行。白名单读取模型比 bwrap 的只读 `/` 更严——只有被挂载的目录可见（`/root`、`/opt`、`/compat`、兄弟挂载均不可达）——这是有意的加固，手册已写明。`--limit-*` 资源控制需要 `kern.racct.enable=1`（开机 tunable，默认关闭）。除非 `--chdir` 补丁被上游合并，否则 boxrun 升级后需重新打补丁。
