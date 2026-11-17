# 复盘 0005：一个失效的 stdio 描述符让服务在每次读图时崩溃

[English](0005-bad-stdio-descriptor-crashed-on-image-read.md) | 中文

状态：已解决

## 摘要

在 FreeBSD 上 `sharp` 没有原生二进制，实际解析到 WebAssembly 构建，而它的 Emscripten 运行时会在**模块求值阶段**对描述符 0、1、2 调用 `fstatSync`。当 stdin 存在却无法 stat——即 `fstat(1)` 显示为 `bad` 的那种状态，也正是控制会话结束时 `revoke(2)` 留下的结果——该调用会抛 `EBADF`，而运行时把它当作**自身异步启动产生的 unhandled rejection** 上报，而不是可捕获的加载错误。于是 `require('sharp')` 「成功」了，但拿到的是半初始化绑定：第一次光栅操作报 `sharp.libvipsVersion is not a function`，那条游离的 rejection 又触发了 fail-loud 处理器，直接退出整个 web 服务。读一张图，甚至只是粘贴一张图，就能让服务下线。所有安全网都没拦住，原因有三：该依赖没有 FreeBSD 原生测试通道、失败经由一条没有任何测试观察的通道抵达、触发条件只有服务环境才会产生。现在加载器在加载前修复描述符 0-2，服务以显式 `</dev/null` 启动；同时顺带发现并修复了服务脚本中一个同族缺陷（FreeBSD `pgrep`/`pkill` 的祖先排除）。

## 概述

服务长期稳定运行，所有非图片工具都正常。任意会话里第一次 `read_image` 就以 `Error: sharp.libvipsVersion is not a function` 失败，几秒后 `dsh_web.log` 出现 `dsh: fatal load failure: ErrnoError { name: 'ErrnoError', errno: 8 }`，进程退出。因为服务是被 `daemon(8)` 托管的子进程，它不会自我重启；运维必须手工重启，而下一次读图又会复发。

触发与图片本身无关：1440x900 截图、64x64 夹具、以及粘贴的图片都能复现。这是两个缺陷叠加。其一是平台形态：FreeBSD 上 `sharp` 经 `@img/sharp-freebsd-wasm32` 解析到 `@img/sharp-wasm32`，该 Emscripten 模块在求值时通过 `fstatSync(0|1|2)` 建立 `/dev/stdin`、`/dev/stdout`、`/dev/stderr` 三条流。其二是环境形态：现场服务进程的描述符 0 处于 `fstat(1)` 显示为 `bad` 的状态——在描述符表里存在，但不可 stat。

两者合起来把一次「加载」变成了「进程退出」。`fstatSync` 抛 `EBADF`；运行时的异步启动把它作为 unhandled rejection 上报，而不是抛加载错误，于是模块停在半初始化状态，`require('sharp')` 返回了一个可调用、但绑定上缺 `libvipsVersion` 的构造函数。随后 `installFailLoud` 对那条游离的 `ErrnoError` rejection 完全按设计行事：输出一行带标签的 stderr，然后 `exit(1)`。

## 影响

所有读图路径都失败，且每次失败都终结服务。`read_image` 是面向模型的截图读取工具，因此正在做界面验证的会话会在回合中途失去 harness；由于服务是单一进程，无关的并发会话也一并死掉。故障还会自我掩盖：工具层错误点名的是 `sharp` 内部符号，而进程层原因是 FreeBSD 的描述符状态，错误信息把人指向了错误的子系统。

没有数据丢失，也没有削弱隔离。会话记录之所以保住，是因为存储在工具返回前已做持久化写入；损失的是可用性与诊断保真度。

## 时间线

- 该日志历史里服务被重启过 48 次，其中三行 `fatal load failure: ErrnoError { errno: 8 }` 此前没有任何解释记录。
- 一个读取 Wine 截图的会话产生 `sharp.libvipsVersion is not a function`，随后是致命的 `ErrnoError` 行；同一特征在另外两个会话里出现，全部发生在 `read_image` 之后。
- 在新进程里验证 `require('sharp')` 完全健康，这正是依赖一开始看起来无辜的原因。
- `fstat -p <服务 pid>` 显示存活进程为 `0 - - bad -`，而它当时仍在监听 `:3080`；对新起进程执行 `fstat -p` 则显示 `/dev/null`。
- 在首次加载前关闭描述符 0-2，可精确复现线上成对症状：`RAW THREW sharp.libvipsVersion is not a function` 加 `UNHANDLED ErrnoError errno=8`。
- 对进程自身的 pty 执行 `revoke(2)` 会得到同样的 `0:EBADF 1:EBADF 2:EBADF`，确认关键在于「该描述符状态」而不只是「已关闭」。
- 修复 stop 路径时，又发现 `pgrep`/`pkill` 的第二个独立缺陷：FreeBSD 默认排除祖先，而加 `-a` 又会过度匹配那些仅仅提到服务字符串的 shell。

## 根因

与持久化无关的事实是：`sharp` 的 FreeBSD 后端是 WebAssembly 模块，因此它会观察到原生绑定不会观察的进程状态——它在加载时对标准描述符做 stat。仓库此前把 `sharp` 当作惰性的纯光栅依赖（[`sharp.ts`](../../packages/attachment/attachment-local/src/sharp.ts) 里的 `createLazyRequire`），这在任何有原生二进制的平台上都准确，在 FreeBSD 上则不成立。

真正让它致命的是失败通道。来自依赖内部异步启动的 unhandled rejection，在处理器看来与 dsh 自身代码的启动失败无法区分——`installFailLoud` 不可能知道这条 rejection 来自 Emscripten 的 `FS.init`。把一切游离 rejection 当作致命，对本仓库是正确的策略；缺陷在于「图片加载」这样一条路径竟然能产生它。

各道安全网为何都没拦住：

- **没有 FreeBSD 原生测试通道。** CI 与开发机把 `sharp` 解析到原生二进制，它根本不对标准描述符做 stat，因此故障在那里不可能出现。FreeBSD 资产只在那个平台才存在的 wasm 路径上被覆盖。
- **测试不关闭描述符。** [`packages/attachment/attachment-local/tests/`](../../packages/attachment/attachment-local/tests/) 中没有任何用例操作描述符表，前提条件从未被构造出来。
- **触发条件需要服务环境。** 交互式 shell 的描述符是健康的；是 `daemon(8)` 加上被 revoke 或不可达的 stdin 才产生 `bad`。手工跑一次看起来完全正常——这正是环境相关缺陷的典型形态。
- **工具错误点名了错误的子系统。** `sharp.libvipsVersion is not a function` 描述的是半初始化绑定，而不是描述符；这句话里没有任何线索指向 `fstat`。

## 新增防护

- [`ensureStandardStreams()`](../../packages/attachment/attachment-local/src/sharp.ts) 对描述符 0-2 做 stat，把不可用的槽位重绑到 `/dev/null`（先 close 再 open，利用「最小空闲描述符号」规则占回同一位）。`requireSharp()` 在加载前调用它；若某个描述符无法恢复就拒绝加载，把致命 rejection 转成可捕获错误。
- [`LocalAttachmentStore`](../../packages/attachment/attachment-local/src/index.ts) 在构造函数里执行同一修复，因此修复发生在挂载期，覆盖粘贴路径，而不是等到第一次光栅操作。
- [`standard-streams.spec.ts`](../../packages/attachment/attachment-local/tests/standard-streams.spec.ts) 固定该修复行为，含幂等性。
- [`dsh_web.rcd`](../../freebsd/dsh_web.rcd) 与 [`dsh-web-restart.sh`](../../freebsd/dsh-web-restart.sh) 以显式 `</dev/null` 启动服务，使被托管进程不再继承失效的描述符 0。
- [`verify-service-match.sh`](../../freebsd/verify-service-match.sh) 断言服务匹配器会忽略非 `node` 进程，且 `status` 反映真实状态。
- 服务脚本与 ports 模板 [`dsh_web.in`](../../dsh-freebsd-port/devel/deepseek-harness/files/dsh_web.in) 改为按精确 argv 识别 harness 并对显式 PID 发信号，取代 `pgrep -f` / `pkill -f`——后者既会漏掉祖先，也可能误杀无关 shell。
- [FreeBSD 启动排错](../../freebsd-startup-troubleshooting.md) 记录了症状、描述符语义与复现方法。

## 经验

- 「惰性依赖」约定是关于「模块何时运行」的声明，而不是关于「它会触碰什么」。WebAssembly 后端可能在加载时观察原生后端忽略的进程状态，因此平台的真实绑定形态才决定这份约定。
- 「存在但不可 stat」是独立于「打开」和「关闭」的第三种描述符状态。`fstat` 能区分它们，而恢复时必须先关掉该槽位再重开，否则新描述符会落到别处。
- 把启动失败以 unhandled rejection 上报的依赖，可以击垮任何装有 fail-loud 处理器的进程，无论失败调用与 rejection 位置多么无关。
- 环境相关缺陷需要与环境同形的复现。要复现这一个，必须真的关闭描述符并 revoke 一个终端，而不是靠 mock。
- FreeBSD 的 `pgrep`/`pkill` 需要 `-a` 才能看见祖先；但对任何要**发信号**的场景，`-a` 加子串匹配仍然不对——应按精确 argv 匹配并显式对 PID 发信号。
