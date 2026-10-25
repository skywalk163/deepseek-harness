# dsh FreeBSD Port — Packaging / Hosting / Testing / Upstreaming Manual

Companion deliverables: `devel/deepseek-harness/` (the port proper) and
`tools/make-port-distfile.sh` (the distfile production script).
The shape decision is described in `README.md`.

---

## 1. Producing the distfile on 1.5

Precondition: the repository `/home/workbuddy/github/deepseek-harness` is in a **built** state
(`lib/`, `apps/web/dist`, and `native/system/packages/freebsd-x64/bin/system.node`
are all present). **Do not run it while a build is in progress** — the `clean` window makes the preflight fail (hit for real on 2026-10-17).

```sh
# 上传并脱离启动（ssh_run.py --file 不传参；脚本无参即自行 detached，
# 默认版本 0.2.1a4；换版本先改脚本里的默认值或本机前台跑
# `sh make-port-distfile.sh 0.2.1a5`）
python tools/ssh_run.py --file dsh-freebsd-port/tools/make-port-distfile.sh

# 跟随日志
python dsh_ssh.py cmd 'tail -f /tmp/mkdist.log' - 60
```

The script does the following in order:

1. **preflight** — checks the three build artifacts plus node/curl; prints the node/pnpm versions.
2. **deploy** — `pnpm --filter @deepseek-ai/dsh deploy --prod <stage>`:
   the CLI's production dependency closure (~290 workspace packages plus npm dependencies, hard-linked from the store).
   A failing `--prod` automatically retries with the full (prod+dev) closure.
3. **fixups** — frontend dist, the freebsd-x64 native addon (copied from the repository if deploy omitted it),
   LICENSE / THIRD_PARTY_NOTICES.md / `freebsd/dsh-jail-run.c`, and removal of tsbuildinfo.
4. **smoke** — when free RAM is at least 1.5GB, start
   `node --expose-internals lib/bin.js web` on 127.0.0.1:3999 with a scratch HOME, require a token line within 90 seconds and
   **200** from `GET /?token=...` (insufficient memory means a loud SKIP that does not block packaging).
5. **tar** — normalize ownership to root:wheel and obtain the checksum with `sha256 -q`.
6. **fragments** — `distinfo.fragment` (SHA256+SIZE, two lines) and
   `pkg-plist.fragment` (the full bundle file list, including the special entries).

Artifacts land in `/tmp/dsh-port-dist/`. **Copy both fragments back into the port directory**
(add one more `TIMESTAMP = $(date +%s)` line to distinfo), then continue to the next step.

## 2. Known traps (observed on 1.5 on 2026-10-17, in the order they were hit)

1. **The stage must live on the same filesystem as the pnpm store**. The store is at
   `/home/workbuddy/.local/share/pnpm/store/v11` (zroot/home/workbuddy);
   a stage under `/tmp` (zroot/tmp) cannot be hard-linked across devices, so pnpm **silently switches to
   /tmp/.pnpm-store and re-downloads every dependency over the network** (an npmmirror timeout simply hangs it).
   That is why `DSH_WORK` defaults to a directory under home.
2. **`pnpm deploy` requires `--legacy`** (verified with pnpm 11.28.5):
   - the default (new) implementation fails outright on a shared lockfile, and the official advice is
     `forceLegacyDeploy: true`;
   - the new implementation resolves workspace packages to absolute `file:///...` paths while the repository's
     `pnpm-workspace.yaml` keys `allowBuilds` relatively as
     `file:packages/...` → mismatch → `strictDepBuilds` turns
     the postinstall of `dsh-subprocess-local` into a hard error
     (ERR_PNPM_IGNORED_BUILDS).
   The legacy implementation has neither problem and still hard-links from the home store (zero network).
3. **`deploy --prod` does not install workspace packages' peerDependencies**:
   `dsh-app-boot` declares `@deepseek-ai/cordis-plugin-group` (vendor/group)
   as a peer, the deploy tree lacks it → every start dies with
   `ERR_MODULE_NOT_FOUND`. The script uses an embedded `reconcile.mjs` to fill the gap from the **workspace
   source directories** (scanning by package.json name, excluding node_modules/.git)
   — **never copy from node_modules**: that tree holds dangling
   symlinks left behind by upstream deletions (cp reports ENOENT) and symlink cycles (cp -RL reports a cycle and emits
   20 levels of nested node_modules).
4. **The deploy tree carries the `uarch` file flag** (the pnpm store has set it since 2026-09-11,
   and hard links inherit it; the live repository node_modules has it too). `rm -rf` reports
   EPERM ("Operation not permitted") for it — a correct owner and mode make no difference.
   Run `chflags -R 0` before cleaning. **This does not affect the port**: tar/cpio do not record BSD
   fflags, so the distfile and the pkg artifacts are clean.
5. **The smoke test must be detached and log itself**: the moment the SSH channel drops, a foreground script is killed by
   SIGPIPE; and if the background node inherits the channel's stdout, `stdout.read()` never
   reaches EOF (a fake hang). The node redirection inside the script is already isolated, and the outer layer adds
   nohup for self-detachment.
6. **Do not run it while a build is in progress**: during the `clean` window `lib/` briefly disappears and the preflight
   goes straight to FATAL (first confirm idleness with `pgrep -fl 'tsc -b|pnpm run build'`).

## 3. Hosting the distfile (GitHub primary + gitcode China mirror)

```sh
VER=0.2.1a4
gh release create freebsd-$VER \
  --repo skywalk163/deepseek-harness \
  --title "FreeBSD runtime bundle $VER" \
  --notes "Prebuilt FreeBSD runtime closure for the devel/deepseek-harness port." \
  /tmp/dsh-port-dist/deepseek-harness-$VER-freebsd-amd64.tar.gz
```

- The Makefile's `MASTER_SITES` is already configured for **GitHub primary + gitcode mirror**, so the ports
  fetch tries them in order and Chinese users automatically take the faster one.
- Whether gitcode mirrors release **attachments** (not just tag archives) needs a real test: after uploading,
  `curl -sI https://gitcode.com/skywalk163/deepseek-harness/releases/download/freebsd-0.2.1a4/deepseek-harness-0.2.1a4-freebsd-amd64.tar.gz`
  should return 200/302. If attachments are not mirrored, drop the gitcode line from MASTER_SITES (or point it
  at the gitcode source archive and host the bundle elsewhere).
- Once the port is in the tree, `distfiles.freebsd.org` caches the distfile automatically, so end users (China included)
  actually download from the official FreeBSD mirrors and GitHub is only the cold-start source.

## 4. Local verification (the /usr/ports shipped with 1.5)

```sh
# port 目录上传到 1.5: /tmp/dsh-port/devel/deepseek-harness
# distfile 放到 DISTDIR（端口构建前 make 会校验 checksum）
DISTDIR=/tmp/dsh-port-dist

make -C /tmp/dsh-port/devel/deepseek-harness DISTDIR=$DISTDIR checksum   # 校验 distinfo
make -C /tmp/dsh-port/devel/deepseek-harness DISTDIR=$DISTDIR stage      # 全量 stage
make -C /tmp/dsh-port/devel/deepseek-harness DISTDIR=$DISTDIR check-plist
```

Points to watch:

- `make stage` produces `${WRKDIR}/stage` — reconcile it against `pkg-plist.fragment` and
  confirm that `USE_RC_SUBR` installs `etc/rc.d/dsh_web` automatically and that the plist needs no hand-written line for it
  (if the plist reports a missing or duplicate entry, add or remove that one `etc/rc.d/dsh_web` line as reported).
- Real-machine install verification (root):
  ```sh
  make -C ... install
  /usr/local/bin/dsh --help                  # wrapper + --expose-internals
  /usr/local/bin/dsh web --port 3999 &       # 冒烟：token URL 200
  ls -l /usr/local/libexec/dsh-jail-run      # 应为 4755 root:wheel
  sysrc dsh_web_enable=YES && service dsh_web start   # rc.d + token 回显
  service dsh_web status
  ```
- Verify the jail helper on its own: `/usr/local/libexec/dsh-jail-run --workspace /tmp --mode read-only -- /bin/echo ok`
  (`sh freebsd/run-verify.sh` in the repository is the full 10/10 criterion; for the port at minimum
  confirm the setuid bit and path resolution).

## 5. Submitting to FreeBSD ports (Bugzilla)

```sh
cd /tmp/dsh-port/devel
tar czf ~/deepseek-harness-port.tar.gz deepseek-harness
# 或 git 格式：在 ports git clone 里 commit 后 format-patch
```

Submission points (write them into the PR description and pre-answer the reviewer):

1. **The legitimacy of bundled node_modules**: dsh is a pnpm monorepo (~290 workspace
   packages) whose full dependency closure is not in the ports tree; a source build needs 30+ minutes and 2–4GB of RAM,
   which poudriere clusters do not accept. The distfile contains `THIRD_PARTY_NOTICES.md`,
   and the port sets `LICENSE=MIT` plus `LICENSE_FILE`.
2. **The setuid binary**: `libexec/dsh-jail-run` (4755 root:wheel) is a necessary part of the FreeBSD
   jail sandbox backend; its code ships inside the distfile (`freebsd/dsh-jail-run.c`), and
   the security model is documented in the file header comments (dropping to the caller's uid inside the jail, workspace path validation).
3. **category=devel**: AI coding agent toolchain; repocopy later if portmgr suggests another category.
4. **Version**: `DISTVERSION=0.2.1a4` → the framework derives `PORTVERSION=0.2.1.a4`
   (Porter's Handbook pre-release rule: letter plus dot first, subsequent digits without a dot).
5. **ONLY_FOR_ARCHS=amd64**: the distfile carries the amd64 native addon; an aarch64 package
   is already on the roadmap (see §5).
6. **The loopback fence**: the Web UI trusts loopback only (a security design), and pkg-message already
   documents SSH tunnel usage — this is not a bug but expected behaviour.

## 6. Roadmap

- **aarch64**: run the same script on an aarch64 FreeBSD machine to produce
  `deepseek-harness-<ver>-freebsd-aarch64.tar.gz`, change the Makefile to
  `DISTFILES= ${PORTNAME}-${DISTVERSION}-freebsd-${ARCH}.tar.gz` and drop
  `ONLY_FOR_ARCHS`.
- **CI automation**: add a gitea (1.5) workflow that runs
  `make-port-distfile.sh` on tag pushes and uploads the release — eliminating the "run it by hand on 1.5" step.
- **Version upgrades**: the fork publishes a new release → re-run the script → update distinfo and DISTVERSION →
  push to the three remotes → update the PR. The `fork-after-upstream-*` baseline tag is the version anchor.
- **Consider splitting the port**: if portmgr objects to the size, split the jail helper into a small standalone port
  (`devel/dsh-jail-run`) and make the main port depend on it.

## 7. Hands-on traps from building and verifying the port locally (2026-10-18)

The traps hit while verifying locally against the `/usr/ports` shipped with 1.5, after the port proper and the distfile were working.
The full session record is in `TASK-LOG-2026-10-18.md`; only the criteria and conclusions are listed here.

1. **`make install` must run as root**: ports convention `su`s to root, so running it as a normal user reports `su: Sorry`.
   Use `ssh_run.py --sudo` to execute remotely as root.
2. **`pkg-plist` must not contain `#` comment lines**: `check-plist` does not accept them and fails outright → delete them.
3. **Do not hand-write `@stopdaemon dsh_web`**: the `USE_RC_SUBR=dsh_web` framework injects that keyword automatically, and
   writing it by hand only duplicates it and fails check-plist.
4. **The `stopdaemon` keyword is missing from the local ports tree**: if the test environment lacks
   `/usr/ports/Keywords/stopdaemon.ucl`, `make install` reports
   `unknown keyword stopdaemon`. The official ports tree ships it; for a test machine, add a `stopdaemon.ucl` that contains only
   `post-install` (calling `service %@ onestop`)
   — **do not give it `actions: [file, dir]`**, or pkg will stat `dsh_web` as a file path and fail.
5. **The verification chain (green)**: `make checksum` → `make stage` →
   `make check-plist` ("No pkg-plist issues found") →
   `make install PREFIX=/tmp/dshtest` (root) lands `bin/dsh` / `etc/rc.d/dsh_web`
   / the setuid `libexec/dsh-jail-run` (4755 root:wheel), and `dsh --help` works.
   The steps for continuing on the 0.88 machine are in `TASK-LOG-2026-10-18.md` §6.
6. **Do not move port files across machines with a 4.8MB heredoc script**: the SSH channel times out with PipeTimeout.
   Use `tools/port_push.py` instead (`sftp.put()` transfers the real files plus `mkdir -p` for directories).
   (`install-port-files.sh` is an obsolete transfer artifact that no longer enters the repository.)
