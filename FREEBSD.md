# DeepSeek Harness on FreeBSD — Installation & Runbook

> **Important: on FreeBSD use this fork (`skywalk163/deepseek-harness`), not upstream `deepseek-ai/deepseek-harness`.**
> The FreeBSD port patches (the `process-inspector` ps-syntax fix, the `terminal-bash` default-shell fix, the `crypto.randomUUID` polyfill, and the loopback-only trust fence) are **not yet merged upstream** and are only maintained in this repository. Cloning upstream would leave those fixes out.

This runbook strings every step from "fresh FreeBSD" to "`dsh web` running" into one linear, copy-paste flow. All commands are verified on FreeBSD 14.3-RELEASE amd64 (Node 24); FreeBSD 15.x works the same (step 2 covers the root cause and fix for the `pnpm install` error seen on 15.1).

---

## 0. Scope & prerequisites

- **Privileges**: installing pkg software needs `root` (or `sudo`/`doas`); running the service uses a normal user (example: `workbuddy`).
- **Network**: the repo-root `.npmrc` already points `registry` and `disturl` at the npmmirror mirror, which makes FreeBSD platform tarballs and the `node-pty` Node-headers download reliable from mainland China. Overseas users may drop those two lines to use the default registry.
- **Security fence (hard limit, not a config toggle)**: the Web UI listens only on `127.0.0.1:3080` (loopback). Any reverse proxy, LAN IP, or public-domain access is rejected with `HTTP 403`. Remote access is **only** possible via an SSH tunnel (step 10).

---

## 1. Install system prerequisites (root or sudo/doas)

```sh
pkg update
pkg install -y node24 npm-node24 gmake python3 pkgconf bash ripgrep
```

| Package | Purpose |
| --- | --- |
| `node24` | Node.js 24 (`engines` requires `^22.19.0 \|\| >=24.0.0`) |
| `npm-node24` | npm that ships with Node24 (on FreeBSD npm is a separate package; `node24` does not bundle it) |
| `gmake` | GNU make. `/usr/bin/make` is BSD make; node-gyp needs GNU make — step 3 adds a shim |
| `python3` | used to compile `node-pty` (3.11 / 3.12 both verified) |
| `pkgconf` | node-gyp / Node-header probing |
| `bash` | **hard dependency**, see step 4; not installed by default on FreeBSD |
| `ripgrep` | provides the system `rg` binary used by the `grep` / `glob` tools as a fallback when the bundled `@vscode/ripgrep` has no FreeBSD native binary (see step 9 and the troubleshooting table) |

Verify versions:

```sh
node -v        # v24.x
npm -v         # 11.x
bash --version # 5.x
gmake --version
python3 --version
```

---

## 2. Critical pitfall: install pnpm via npm, disable corepack (root cause of the 15.1 error)

### Symptom

On FreeBSD 15.1 (and on any FreeBSD where pnpm was installed via **corepack / standalone**) running `pnpm install` fails with:

```
[ERROR] Cannot verify the identity of the @pnpm/exe.freebsd-x64 native binary:
        it is missing from pnpm-lock.yaml
```

### Root cause

pnpm v10 / v11 ships itself as a platform-native binary `@pnpm/exe-<os>-<arch>`. When pnpm runs via **corepack / standalone**, it verifies that native binary's identity against `pnpm-lock.yaml`. But this repo's `pnpm-lock.yaml` was generated on **another platform using the npm-installed pnpm**, so it contains **no `@pnpm/exe` entry at all** (confirmed: the lockfile has 80 `freebsd` references but 0 `@pnpm/exe` / `exe-freebsd-x64` entries). On FreeBSD there is naturally no `freebsd-x64` exe entry to verify against → verification fails.

### Fix / prevention (do exactly this)

**Install pnpm via npm; do not enable corepack.**

```sh
# Install globally (as root or your user). This installs the pure-JS launcher
# pnpm.cjs that runs under node and does NOT perform the @pnpm/exe identity
# check, so it succeeds on FreeBSD.
npm install -g pnpm@11.7.0
```

> ⚠️ **Do not** run `corepack enable` or `corepack prepare pnpm@...`. corepack installs pnpm on the standalone native-binary path — that is exactly the route that triggers the error above.
>
> **Version note**: the repo's `package.json` pins `packageManager` to `pnpm@11.7.0`; aligning is recommended. But any **npm-installed** pnpm works (the box currently running 10.28.0 is also a JS launcher) — **method matters more than version**.

Verify pnpm really is the JS launcher (the correct form):

```sh
readlink -f "$(which pnpm)"
# should point to .../node_modules/pnpm/bin/pnpm.cjs
head -1 "$(which pnpm)"
# should be #!/usr/bin/env node
pnpm -v
```

If you already used corepack and are stuck on the error, clear the shim and reinstall via npm:

```sh
corepack disable 2>/dev/null
npm install -g pnpm@11.7.0
```

---

## 3. GNU make shim (node-gyp needs it)

FreeBSD's `/usr/bin/make` is BSD make, but node-gyp must invoke GNU make under the name `make`. Symlink it and put it first on `PATH`:

```sh
mkdir -p "$HOME/bin"
ln -sf /usr/local/bin/gmake "$HOME/bin/make"

# Persist across logins:
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.shrc
# If you log in with bash, write ~/.bashrc instead:
# echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

Re-login or `source ~/.shrc`, then verify:

```sh
which make       # should point to $HOME/bin/make -> /usr/local/bin/gmake
make --version   # GNU Make 4.x
```

---

## 4. bash hard dependency (terminal-bash backend)

The `code` / `mini` agent modes depend on the `terminal-bash` backend, which uses bash-only features:

- `PROMPT_COMMAND` emits the per-prompt OSC `133;D;` marker that the harness reads to know when a command finished and with what exit status;
- the default shell flags `--noprofile --norc -i` are bash-only.

FreeBSD's default shell is `/bin/sh` (an ash derivative) and **cannot be substituted**. If bash is missing the service fails with `PTY shell exited during startup` (or, with the bundled guard, a clear `terminal-bash: ... does not exist` message).

```sh
pkg install -y bash    # already done in step 1; confirm
which bash             # /usr/local/bin/bash
```

The repo added a check in `packages/terminal/terminal-bash/src/config.ts`: when shellPath is missing or not bash it fails with a clear error instead of silently falling back to a non-existent path.

---

## 5. .npmrc (node-pty needs Node headers)

The repo-root `.npmrc` already contains:

```
registry=https://registry.npmmirror.com
fetch-retries=5
fetch-retry-maxtimeout=120000
fetch-timeout=300000
disturl=https://registry.npmmirror.com/-/binary/node
```

`disturl` makes `node-pty` automatically download the matching Node headers at compile time, so no manual `--nodedir` is needed. Keep those two lines (`registry` / `disturl`). Overseas users may switch to the default registry (drop the first two lines) but must keep the ability to fetch Node headers.

---

## 6. Clone the repo (from our own fork)

```sh
cd ~
git clone https://gitcode.com/skywalk163/deepseek-harness.git
# or the GitHub mirror:
# git clone https://github.com/skywalk163/deepseek-harness.git
cd deepseek-harness
git log --oneline -1   # should show a FreeBSD-port commit
```

> Do not clone upstream `deepseek-ai/deepseek-harness` — the FreeBSD patches are not merged there and would be missing.

---

## 7. Install dependencies

```sh
pnpm install
```

This compiles the `node-pty` native addon (needs gmake, python3, pkgconf, disturl from steps 1 / 3 / 5). If it hangs on ETIMEDOUT fetching Node headers, check `.npmrc`'s `disturl` and network connectivity.

---

## 8. Build

After changing source you must rebuild (the web command only serves the prebuilt `apps/web/dist`):

```sh
pnpm run build     # = build:lib (tsc -b + tsdown) + build:web (vite)
```

---

## 8.1 Enable the FreeBSD jail sandbox (recommended)

Instead of running the agent unconfined (`danger-full-access`), you can confine every `code` / `mini` / `standard` command inside a **real FreeBSD jail**. The harness's local sandbox provider selects this backend automatically on FreeBSD once the setuid helper `dsh-jail-run` is installed — no `danger-full-access` needed.

### Build & install the setuid helper (root)

```sh
cc -O2 -Wall -ljail -o /usr/local/sbin/dsh-jail-run freebsd/dsh-jail-run.c
chmod 4755 /usr/local/sbin/dsh-jail-run
chown root:wheel /usr/local/sbin/dsh-jail-run
```

On hosts where `/usr` is a **read-only** mount (this one), write the binary under `/var` instead and point the harness at it via `DSH_JAIL_RUN_BIN`:

```sh
cc -O2 -Wall -ljail -o /var/dsh-jail-run freebsd/dsh-jail-run.c
chmod 4755 /var/dsh-jail-run
chown root:wheel /var/dsh-jail-run
# the freebsd/dsh-web-run.sh launcher already defaults DSH_JAIL_RUN_BIN to /var/dsh-jail-run
```

### Security notes (read `freebsd/dsh-jail-run.c` before touching it)

- The binary is **setuid-root**. Any local user who can execute it can create jails — but the command always runs **inside** the jail as the *original* (non-root) caller uid/gid. Root is used only to (a) create the jail and (b) mount the read-only system view, then privileges are dropped via `setuid`/`setgid` in the child. **No silent privilege escalation**: without the setuid bit the program can only create jails when already root, and the harness never grants root.
- The workspace you pass is the **only** writable host directory exposed. Everything else is a read-only `nullfs` mount or a fresh `tmpfs`; the jail has **no network** by default (opt in with `--network` or `DSH_JAIL_NETWORK`).
- The binary must be root-owned and not group/world writable, and live in a directory non-root users cannot rename/replace.

### What the backend does

`dsh-jail-run --workspace <root> --mode <read-only|workspace-write> -- <command...>` builds an ephemeral jail rooted at a fresh dir, mounts the host system read-only + the workspace (read-only or read-write) + a restricted `devfs` (ruleset 4) + a fresh `tmpfs` at `/tmp`, attaches, drops to the caller, `chdir`s to `/workspace`, and `exec`s the command. The jail is removed (mounts unmounted) on command exit. The harness wires this for `read-only` / `workspace-write`; `danger-full-access` remains an explicit escape hatch.

### Verify

```sh
sh /tmp/dsh-jail-test.sh   # drops to caller uid, cwd=/workspace, ro denies writes,
                            # no network, clean teardown (9/9 checks)
```

(The full contract is in `freebsd/dsh-jail-run.c` and the `freebsd-jail.e2e.ts` test.)

---

## 9. Run the Web UI

```sh
pnpm dsh:freebsd web                       # confined by default (jail sandbox, if helper installed)
# or opt out entirely (explicit escape hatch):
DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
```

- **Default working directory.** The harness routes every `bash` / `grep` / terminal command's cwd through `session.header.cwd`, which falls back to `process.cwd()` (the directory this command runs in) when the web UI does not set a per-task project directory. If you launch from the repo root, commands default to the repo — set the project explicitly with the `DSH_PROJECT_DIR` env var (the `freebsd/dsh-web-run.sh` launcher honors it; otherwise `cd` into your project before launching). Until the web fork wires the task "项目目录" field into `header.cwd`, this is the dependable way to make your project the default working directory.

- `dsh:freebsd` = normal `dsh` + `--expose-internals`. On FreeBSD the HMR service requires that flag, and it **cannot** be passed via `NODE_OPTIONS` (`node-addon-require-builtin` only ships darwin/linux/win32 prebuilds; no FreeBSD native package and no source fallback).
- **FreeBSD now ships a jail sandbox backend (recommended).** The local sandbox provider selects a real FreeBSD jail automatically once the setuid `dsh-jail-run` helper (section 8.1) is installed — so `read-only` / `workspace-write` modes run **inside a jail** instead of failing closed. `danger-full-access` is still available as an explicit escape hatch (set `DSH_PERMISSION_MODE=danger-full-access`) for hosts where the helper cannot run. If the helper is **not** installed, the old behavior holds: confined modes fail closed with `SANDBOX_UNAVAILABLE` and you must use `danger-full-access`.
- ⚠️ **`code` / `mini` modes are exactly where the jail bites — in a good way.** They drive a persistent PTY bash session through the sandbox-confined bash executor. With the `dsh-jail-run` helper installed, every `bash`/`ls`/file command runs confined in a jail whose only writable host directory is the workspace; outside the workspace the filesystem is read-only and there is no network. If the helper is **not** installed, the session aborts with:
  ```
  Error: sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host;
  refusing to run the command unconfined. Install the `dsh-jail-run` setuid helper (see section 8.1)
  or, to opt out, switch to `danger-full-access`: launch with DSH_PERMISSION_MODE=danger-full-access,
  or pick the danger-full-access permission preset in the UI.
  ```
  This error is **by design (fail-closed), not a crash.** Install the helper (recommended) or set `DSH_PERMISSION_MODE=danger-full-access` to opt out.
- Listens on `http://127.0.0.1:3080` by default.

---

## 10. Remote access: SSH tunnel (the only allowed way)

The Web UI **only answers loopback addresses** (`localhost` / `127.0.0.1` / `[::1]`). Reverse proxy, LAN IP, and public domain all get `HTTP 403` (the harness's host-side RPC trust fence rejects any non-loopback `Host` before the handler runs — even "choose workspace directory" fails).

On your workstation:

```sh
ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>
```

Then open `http://localhost:3080`. The tunnel gives both a loopback `Host` (no 403) **and** a secure context (native `crypto.randomUUID` works) — both pitfalls disappear at once.

On the FreeBSD box itself just open `http://127.0.0.1:3080`.

---

## 11. Running as a service (restart script + rc.d)

The repo ships path-independent helper scripts under `freebsd/` (they resolve the repo root from their own location, so clone anywhere). For a custom project directory, set `DSH_PROJECT_DIR` in the service env (see below) — the launcher `cd`s into it before starting, making it the default working directory for all commands.

- `freebsd/dsh-web-run.sh` — launcher: no longer forces `DSH_PERMISSION_MODE` (defaults to the harness's confined mode so the jail sandbox engages; set it only to opt out), points `DSH_JAIL_RUN_BIN` at the helper (defaults to `/var/dsh-jail-run` on this read-only-`/usr` box), `cd`s into `DSH_PROJECT_DIR` (default repo root), and `exec`s `pnpm dsh:freebsd web`.
- `freebsd/dsh-web-restart.sh` — one-shot control: `stop | start | restart | status` (default `restart`).

```sh
sh freebsd/dsh-web-restart.sh restart   # also: stop / start / status
DSH_PROJECT_DIR=/home/skywalk/dswork sh freebsd/dsh-web-restart.sh restart   # with a project dir
```

For boot-time autostart (needs root):

```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
sysrc dsh_web_chdir="$(pwd)"          # repo absolute path, filled automatically
sysrc dsh_web_projectdir="/home/skywalk/dswork"   # optional: default project dir
service dsh_web start        # verify
service dsh_web status
```

Notes:

- `pnpm` must be persisted (on this box at `/home/<user>/.local/bin/pnpm` v11.7.0); do not rely on a `/tmp/p117`-style path that `/tmp` cleanup would wipe on reboot.
- The rc.d `pidfile` and log live inside the repo (`dsh_web.pid`, `dsh_web.log`) so they survive reboots and `/tmp` cleanup.
- The rc.d service runs as the `dsh_web_user` (default `workbuddy`); change via `sysrc dsh_web_user=...` if you installed elsewhere.

---

## 12. Git: three remotes & lefthook bypass (only if you push patches back)

This repo has three remotes:

```sh
git remote -v
# origin   https://gitcode.com/skywalk163/deepseek-harness (fetch/push)
# github   git@github.com:skywalk163/deepseek-harness.git
# gitea    http://192.168.1.5:3000/skywalk/deepseek-harness.git
```

On commit / push, **lefthook's `gen-third-party-notices` hook fails on FreeBSD because it needs `@anthropic-ai/claude-agent-sdk-linux-x64` (Linux-only build)** — unrelated to your change. Bypass:

```sh
git commit --no-verify
git -c core.hooksPath=/tmp/nohooks push <remote> <branch>
```

(Inject the token into the URL when pushing to gitcode / gitea, per the repo's existing convention.)

---

## 13. Troubleshooting table

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Cannot verify the identity of the @pnpm/exe.freebsd-x64 native binary: it is missing from pnpm-lock.yaml` | pnpm installed via corepack / standalone triggers the `@pnpm/exe` identity check; lockfile has no freebsd-x64 exe entry | **Use `npm install -g pnpm@11.7.0`** (JS launcher, no check); disable corepack. See step 2. |
| `Could not load the "sharp" module using the freebsd-x64 runtime` | `sharp` has no FreeBSD native binary; WASM path not installed | Keep `supportedArchitectures` (`os: freebsd`, `cpu` includes `wasm32`) and the `sharp` `packageExtensions` in `pnpm-workspace.yaml`. |
| `ERR_MODULE_NOT_FOUND` for `@deepseek-ai/dsh-client-ui-*` | workspace plugins not hoisted | Keep `shamefullyHoist: true` in `pnpm-workspace.yaml`. |
| `--expose-internals is required for HMR service` | native-addon route unavailable on FreeBSD | Use the `dsh:freebsd` script (adds `--expose-internals`). Flag cannot go in `NODE_OPTIONS`. |
| `sandbox mode "..." is requested but no sandbox backend is usable` (`SANDBOX_UNAVAILABLE`) in `code` / `mini` mode | `dsh-jail-run` setuid helper not installed (FreeBSD has no *built-in* backend; it needs this helper) | **Install the helper** (section 8.1) — confined modes then run inside a jail. Or, to opt out, set `DSH_PERMISSION_MODE=danger-full-access` at launch / pick the **danger-full-access** preset. Fail-closed-by-design, not a crash — see step 9. |
| `crypto.randomUUID is not a function` | non-secure context (plain http, non-localhost) | Browse via `http://localhost:3080` (SSH tunnel). Polyfill included, but prefer localhost. |
| `transport failure for /api/host.listDirectory: HTTP 403` | loopback trust fence rejects non-loopback `Host` | Reach the UI via SSH tunnel / `localhost` (see step 10). Do **not** use a reverse proxy or LAN IP. |
| `node-pty` build fails / ETIMEDOUT fetching Node headers | node-gyp cannot reach headers | Keep `disturl=https://registry.npmmirror.com/-/binary/node` in `.npmrc`; ensure the gmake shim is on `PATH`. |
| `PTY shell exited during startup` / `terminal-bash: ... does not exist` | `bash` not installed (FreeBSD ships `/bin/sh`, not bash) | `pkg install bash`; the backend cannot use the default `/bin/sh`. |
| `gen-third-party-notices` hook fails on commit/push | upstream hook needs Linux-only claude-agent-sdk | FreeBSD platform incompatibility, unrelated to your change. Bypass with `git commit --no-verify` or `git -c core.hooksPath=/tmp/nohooks push`. |
| `grep` / `glob` fail with `could not start its search command (ripgrep launch failed)` | `@vscode/ripgrep` ships no FreeBSD native binary, so its `rgPath` points at a missing file | `pkg install ripgrep`, then the `grep`/`glob` tools auto-fall-back to the system `rg` (or set `DSH_RIPGREP_PATH` to your `rg`). Fixed in code at `packages/fs/tool-fs-search/src/search-core.ts`. |
| `bash` / `grep` run in `$HOME` (or the repo root) instead of the project you set in the task | the web fork does not yet wire the task "项目目录" field into `session.header.cwd`; the command cwd falls back to `process.cwd()` (where `dsh web` was launched) | set the project explicitly: launch with `DSH_PROJECT_DIR=/path/to/project`, or in the rc.d service `sysrc dsh_web_projectdir="/path/to/project"`. The `freebsd/dsh-web-run.sh` launcher `cd`s into it. |

---

## 14. Verified on FreeBSD

`node-pty` compiles natively, `sharp` renders through WASM, `pnpm run build` completes (`tsc -b` + `tsdown` + `vite`), and `dsh web` serves the UI over HTTP on loopback.
