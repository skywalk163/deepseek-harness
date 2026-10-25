# dsh FreeBSD Port — Delivery Notes

English | [中文](README.zh.md)

Package the self-maintained FreeBSD build of deepseek-harness (dsh) as a proper
FreeBSD port, so a user reaches a working install with `make install` /
`pkg install deepseek-harness`.

## Shape decision (stated up front to avoid misunderstanding)

**The port directory holds only "installer" material (Makefile/pkg-plist/rc.d/wrapper), no source at
all**; the distfile (self-contained runtime bundle) is downloaded from GitHub at `make fetch` time, with
gitcode as the China mirror. This is exactly the model requested. But **the distfile is not a source
tarball, it is a prebuilt runtime closure**, for these reasons:

1. The FreeBSD ports **build phase forbids network access** — dependencies must come either from the ports
   tree or be carried inside the distfile. dsh is a pnpm monorepo of ~290 workspace packages with ~1500
   npm dependencies (including the node-pty native patch, sharp wasm, and per-platform native packages)
   that barely exist in the ports tree.
2. Building from source on site requires `pnpm install` + `pnpm run build`: **30+ minutes and a 2–4GB
   peak memory footprint**. A poudriere cluster builder (8GB RAM, strict time limits) rejects it outright,
   and a half-hour wait inside `make install` is not an experience either.
3. Precedent: complex applications such as OnlyOffice and VS Code server take the same "download prebuilt
   artifacts + install" shape in ports.

The only thing compiled in the port is `freebsd/dsh-jail-run.c` (the setuid jail helper, ~600 lines of C,
using jail(2) only, with no external dependencies).

## File layout

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

## Status

- [x] Reconnaissance: runtime closure = the 287-package production dependency graph of the CLI (reachability analysis confirms the whole agent core stack is inside)
- [x] Port skeleton (Makefiles/rc.d/wrapper/pkg-message)
- [x] Distfile production script (pnpm deploy --legacy --prod + boot smoke + tar + fragment output)
- [x] Deploy route verified end to end on 1.5: `--legacy` sidesteps the shared-lockfile defect + allowBuilds mismatch;
      home store hard links mean zero network; node-pty build output/flock addon/web dist all present
- [x] Found and fixed missing peer dependencies: dsh-app-boot and others declare cordis-plugin-group as
      peerDependencies, which `pnpm deploy --prod` does not install — the script fills the missing packages
      from the workspace source directories with node (not from node_modules symlinks, which contain dangling links and cycles)
- [x] **Fixed a non-portable distfile**: workspace packages in the deploy tree were "symlinks pointing back at the
      build machine's source repo", so they dangled on any other machine → `dsh` died with `ERR_MODULE_NOT_FOUND`;
      the script gained a "dereference" step and a re-run made the distfile (62,207,174 B) pass
      `make install` + `dsh --help` on 1.5
- [x] Final run: smoke green → **distinfo/pkg-plist filled in** (SHA256 + SIZE + TIMESTAMP are in distinfo)
- [x] Real-machine `make checksum/stage/check-plist` + `make install PREFIX=/tmp/dshtest` on 1.5 all green
      (bin/dsh, etc/rc.d/dsh_web, setuid libexec/dsh-jail-run all landed correctly,
      check-plist reported "No pkg-plist issues found")
- [x] **This document is archived in `TASK-LOG-2026-10-18.md`**, and pushed to gitea `skywalk/deepseek-harness`
      (as the `dsh-freebsd-port/` subdirectory, so the 0.88 machine can just `git fetch` to continue)
- [ ] GitHub release hosting + gitcode mirror (the distfile is built but not uploaded, see PORTING.md §3)
- [ ] The submission checklist in PORTING.md (Bugzilla filing)
