# DeepSeek Harness (dsh) FreeBSD jail Sandbox Backend — Deployment & Ops Manual (blind-followable for beginners)

> Audience: someone who has never touched this repo but needs to get the jail sandbox running on FreeBSD and be able to troubleshoot it.
> Companion top-level manual: `FREEBSD.md` / `FREEBSD.zh.md` (§8.1 cross-references this document).
> Every command below was run live on **FreeBSD 14.3-RELEASE-p7 amd64**. The "Verified state" section gives results you can reproduce exactly.

---

## 0. What this manual covers / does not cover

- **Covers**: the FreeBSD jail sandbox backend (the setuid-root `freebsd/dsh-jail-run.c` helper) — **compile, install, configure, start, verify, troubleshoot, secure, upgrade**.
- **Does not cover**: kernel recompilation, changing jail internals, or defending against kernel exploits. This is harness-side usage documentation only — you do not need to rebuild the kernel or touch jail source (unless you upgrade the helper; see Chapter 8).

After reading this you should be able to:
1. Get the sandbox running on a clean FreeBSD 13+/14.x.
2. Confirm isolation with one command (10/10, 5/5).
3. Locate the root cause from the troubleshooting table when something breaks.

---

## 1. Overview & architecture in one minute

dsh has **no built-in sandbox backend on FreeBSD** (upstream only knows Linux bwrap/Landlock, macOS Seatbelt, Windows ACL restricted-token). This repo adds a **real FreeBSD jail backend** driven by the setuid-root `dsh-jail-run` helper.

When a `code` / `mini` / `standard` command is dispatched, the harness's local sandbox provider does this:

```
your command argv
   │  confine()
   ▼
dsh-jail-run --workspace <host workspaceRoot> --mode <read-only|workspace-write> -- <your command>
   │
   ├─ 1. Validate workspace: must be absolute, realpath-resolved with no "..", and not "/"
   ├─ 2. Build an ephemeral jail in a root-owned temp dir (jailparam_set, persist=1)
   ├─ 3. Mount (all still as root, before the child drops privileges):
   │      • host system dirs (/bin /sbin /lib /etc /usr/bin ...)  —— read-only nullfs
   │      • workspace (the root you specified)                      —— read-only, or rw for workspace-write
   │      • /dev —— restricted devfs (ruleset 4, only jail-appropriate devices)
   │      • /tmp —— fresh tmpfs (dies with the jail, never touches host /tmp)
   │      • /var/run/ld-elf.so.hints —— read-only nullfs (so the linker finds /usr/local/lib)
   ├─ 4. jail_attach into the jail
   ├─ 5. setuid/setgid down to the ORIGINAL caller (never stays root)
   ├─ 6. chdir to /workspace, exec your command
   └─ 7. On exit → parent unmounts everything + removes jail + cleans temp dir
```

**Key isolation boundaries (strong least-privilege for the agent):**
- Filesystem: the only writable host directory is `workspace`; everything else is read-only `nullfs` or fresh `tmpfs`; `/` is explicitly refused.
- Network: **off by default** (`ip4=disable`, `ip6=disable`). Opt in explicitly with `--network` or the `DSH_JAIL_NETWORK=1` env var.
- Resources: `rctl` caps `maxproc:deny=256`, `pcpu:deny=90` (see Chapter 2, `kern.racct.enable`).
- Process view: `enforce_statfs=2` — the jail only sees its own filesystems.

**Why setuid-root is needed:**
Creating the jail and mounting the read-only system view require root. But that privilege is used **only for the instant the jail is built, still in the parent process**; the child `exec`s your command only after `setuid`-dropping back to the caller. So the binary must be setuid-root, but **it does not run your command as root** — by design, not a privilege-escalation backdoor.

**`danger-full-access` is only an escape hatch.** With the helper installed the harness auto-selects the jail backend and doesn't need it. Use `DSH_PERMISSION_MODE=danger-full-access` only when the helper genuinely cannot be installed (see Chapter 4).

---

## 2. System prerequisites (FreeBSD 13+, tested 14.x)

### 2.1 Kernel options self-check (JAIL / NULLFS / TMPFS / DEVFS / RACCT / RCTL)

The FreeBSD **GENERIC amd64 default kernel already includes** JAIL, NULLFS, TMPFS, DEVFS, RACCT, RCTL. You **do not** need to recompile the kernel.

⚠️ **A trap worth knowing (verified live)**: on a stock GENERIC kernel, `config -x /boot/kernel/kernel` will **not necessarily** list these options line by line. On this 14.3 box, `config -x | grep -iE 'jail|nullfs|devfs'` returned **0 lines** (only RACCT/RCTL/TMPFS appeared). So **do not** treat "JAIL not in config -x" as "kernel lacks jail" — that's just `config -x` behavior, not a missing feature. **The authoritative check is: `verify-sandbox.mjs` in Chapter 5 returns 10/10.**

Confirm the capabilities actually exist:

```sh
# nullfs: present as a loadable module (this box: nullfs.ko is loaded)
kldstat -n nullfs
# expected:
# Id Refs Address                Size Name
#  3    1 0xffffffff821d8000     97f8 nullfs.ko

# tmpfs: compiled into GENERIC, no separate .ko is normal — means it's always resident
kldstat -n tmpfs || echo "tmpfs is built into the kernel (no separate module — normal)"

# devfs: always mounted at /dev
mount | grep -w devfs
# expected: devfs on /dev (devfs)

# jail: confirm kernel support via the sysctl namespace
sysctl security.jail 2>/dev/null | head -1

# RACCT/RCTL compiled in (these are what config -x shows)
config -x /boot/kernel/kernel 2>/dev/null | grep -iE 'RACCT|RCTL'
```

**If something's wrong**: if `kldstat -n nullfs` fails and you're on a minimal kernel, add `nullfs_load="YES"` to `/boot/loader.conf` and reboot (2.2). If `config -x | grep -iE 'RACCT|RCTL'` is empty, your kernel lacks RACCT/RCTL — but GENERIC always has them, so this means a non-GENERIC kernel; switch back to GENERIC or compile in `options RACCT` / `options RCTL`.

### 2.2 `loader.conf`: enable rctl resource limits

`dsh-jail-run.c`'s `apply_rctl()` adds `maxproc` / `pcpu` caps per jail. It calls `rctl`, which requires kernel RACCT **enabled at runtime**.

Check current state:

```sh
sysctl kern.racct.enable
# expected: kern.racct.enable: 1
```

If `0`, write to `/boot/loader.conf` and **reboot** to apply:

```sh
# needs root
echo 'kern.racct.enable=1' >> /boot/loader.conf
# also guarantee the nullfs module is available (GENERIC already has it; this line is harmless)
echo 'nullfs_load="YES"' >> /boot/loader.conf
reboot
```

⚠️ **Behavior note (confirmed by reading `dsh-jail-run.c`)**: `apply_rctl()` runs `rctl -a ... 2>/dev/null` via `system()`, and **failures are silently ignored** (stderr discarded, no warning, jail creation proceeds). So if `kern.racct.enable` is off, the jail **still runs**, just **without the maxproc/pcpu caps**. It's a hardening item, not a hard requirement — but enable it in production.

### 2.3 `rc.conf` and `devfs.rules`: what ruleset 4 means

`rc.conf` usually only needs devfs enabled at boot (default on most setups; no change needed). This box's `/etc/rc.conf` has only `devfs_system_ruleset="vbox"`, which is unrelated to the jail sandbox — leave it alone.

**What ruleset 4 is**: `dsh-jail-run.c` mounts `/dev` by hand with `mount -t devfs -o ruleset=4 devfs <dst>`. Ruleset 4 is the system-builtin **`devfsrules_jail`** (jail device rules: only `null`/`zero`/`random`/`tty`/`pty*` etc., no dangerous `mem`/`kmem`/`io`). It ships with the system as the **default jail ruleset** — you do **not** need to define it in `/etc/devfs.rules`.

```sh
# Your /etc/devfs.rules may only contain unrelated stuff (this box: vbox=10) — that's fine:
cat /etc/devfs.rules
# [vbox=10]
# add path 'vboxnetctl' mode 0666 group operator
# ...

# ruleset 4 is provided by the system defaults; confirm (needs root to read defaults):
sudo grep -i jail /etc/defaults/devfs.rules 2>/dev/null || echo "(need root to read defaults; doesn't affect usage)"
```

**If something's wrong**: if `/dev` inside the jail is broken (e.g. `bash` won't start, missing `/dev/null`), first confirm devfs is in the kernel (2.1). The only way ruleset 4 goes missing is if you manually deleted it from `/etc/defaults/devfs.rules` — restore the default, or change the `ruleset=4` in `dsh-jail-run.c` to your custom ruleset number (not recommended).

### 2.4 Other default behaviors

- `security.jail.enforce_statfs` system default is **2** (jail sees only its own filesystems). `dsh-jail-run.c` also explicitly sets `enforce_statfs=2` per jail — double safety.
- tmpfs / nullfs are built into GENERIC, no extra `kldload` needed (2.1 confirmed nullfs module is loaded).

---

## 3. Compile & install the setuid binary (the critical, most error-prone chapter)

Source: `freebsd/dsh-jail-run.c`. After compiling you need a setuid-root install location.

### 3.1 Normal install (when /usr is writable)

```sh
# Run from the repo root
cd /home/workbuddy/github/deepseek-harness   # replace with your repo path

# 1) Compile (link libjail)
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c

# 2) Install as setuid-root with root:wheel, mode 4755
install -o root -g wheel -m 4755 dsh-jail-run /usr/local/sbin/dsh-jail-run
```

**Expected output**: no compile errors; `ls -l /usr/local/sbin/dsh-jail-run` shows:

```
-rwsr-xr-x  1 root wheel  21312  ...  /usr/local/sbin/dsh-jail-run
```

Note the leading **`-rws`** (s in the owner-exec position = setuid).

### 3.2 ⚠️ This box's special case: /usr is read-only → install to /var

**This box's `/usr` is a read-only mount**, so you can't write `/usr/local/sbin`. Install under `/var` and point `DSH_JAIL_RUN_BIN` at it:

```sh
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c
install -o root -g wheel -m 4755 dsh-jail-run /var/dsh-jail-run
```

`freebsd/dsh-web-run.sh` already defaults `DSH_JAIL_RUN_BIN` to `/var/dsh-jail-run`, so just use it here. Verify manually:

```sh
ls -l /var/dsh-jail-run
# -rwsr-xr-x  1 root wheel  22240  ...  /var/dsh-jail-run
```

**If something's wrong**:
- Compile error `cannot find -ljail` → missing jail dev libs: `pkg install -y libjail` (or missing headers; base system normally has `/usr/include/jail.h` and `/usr/lib/libjail.*`).
- `cc: command not found` → `pkg install -y llvm`, or use the base-system `cc` (clang, should exist).

### 3.3 ⚠️ The binary must live on a NON-nosuid filesystem

The setuid bit only takes effect on a filesystem **not mounted `nosuid`**. This box's `/tmp` is a nosuid ZFS dataset:

```sh
mount | grep -iE 'nosuid|tmpfs' | grep -w /tmp
# zroot/tmp on /tmp (zfs, local, noatime, nosuid, nfsv4acls)   ← nosuid means NEVER put it here
```

**Conclusion: never install `dsh-jail-run` under `/tmp` or any `nosuid` mountpoint** (including `/var/tmp`, which is also nosuid here). Otherwise the kernel ignores the setuid bit, the binary runs as the caller, can't build jails, and you get `SANDBOX_UNAVAILABLE`. `/usr/local/sbin` and `/var` are normal mounts — safe.

### 3.4 Verify setuid + automatic privilege drop

A non-root user should be able to execute it directly (it auto-drops to the caller):

```sh
# As a normal user (e.g. workbuddy), confirm it builds a jail and runs as you:
dsh-jail-run --workspace "$HOME" --mode read-only -- id
# expected: prints the caller's uid/gid inside the jail (not 0), cwd is /workspace
```

**If something's wrong**: `permission denied` / `operation not permitted` during jail creation → check (a) perms really are `-rwsr-xr-x root wheel`; (b) the filesystem is non-nosuid (3.3); (c) you're running as a normal user (running as root, `getuid()==0`, drop keeps 0 — expected but not demonstrative).

### 3.5 Security statement (read before proceeding)

`setuid-root` is double-edged. This binary's design tightly contains the privilege:

- The binary is root **only for the instant it builds the jail + mounts the read-only system view**, then the child immediately `setuid`s back to the caller. **No silent privilege escalation**: without the setuid bit the program can only build jails when already root, and the harness never grants you root.
- The `workspace` you pass is the **only** writable host directory exposed; everything else is read-only `nullfs` or fresh `tmpfs`; `/` is explicitly refused.
- The binary must be **root-owned and not group/world-writable**, and live in a directory non-root users **cannot rename/replace** (`/usr/local/sbin`, `/var` both qualify). If you put the binary in a user-writable directory, any local user can replace it and execute arbitrary code as root — **the #1 setuid risk**.
- Upgrading/reinstalling the binary requires root and a fresh `install` (Chapter 8).

---

## 4. Configure & start the web service

### 4.1 What `freebsd/dsh-web-run.sh` does

The launcher lives at `<repo>/freebsd/dsh-web-run.sh`, derives the repo root from its own location, **no path editing needed**. Key points:

- **Does NOT force `danger-full-access` by default.** It only exports `DSH_PERMISSION_MODE` if it's already set; otherwise leaves it empty so the harness picks its default confined mode (i.e. the jail sandbox). With the helper installed, that's what you want.
- Defaults `DSH_JAIL_RUN_BIN` to `/var/dsh-jail-run` (fits this box's read-only `/usr`; for a normal install override with `DSH_JAIL_RUN_BIN=/usr/local/sbin/dsh-jail-run`).
- Adds `node`/`pnpm` (from `/usr/local`) and the `~/bin/make` shim to `PATH` (covers both interactive shells and the minimal PATH of rc.d boot).
- `cd`s into `DSH_PROJECT_DIR` (default repo root), then `exec pnpm dsh:freebsd web`.

### 4.2 Start (daemonized + loopback-bound)

The repo ships `freebsd/dsh-web-restart.sh` (`[stop|start|restart|status]`, default `restart`):

```sh
cd /home/workbuddy/github/deepseek-harness
sh freebsd/dsh-web-restart.sh restart
# or: stop / start / status

# Make every command default to a project dir (instead of repo root):
DSH_PROJECT_DIR=/home/workbuddy/dswork sh freebsd/dsh-web-restart.sh restart
```

Under the hood it uses `/usr/sbin/daemon` to persist the web process; **logs and pidfile live in the home dir** (`/home/workbuddy/dsh_web.log`, `/home/workbuddy/dsh_web.pid`) to survive `/tmp` cleanup across restarts.

**Expected output**: `status` shows the `dsh:freebsd web` process running; `tail -f /home/workbuddy/dsh_web.log` shows it listening on `http://127.0.0.1:3080`.

Boot-time auto-start (needs root; see `FREEBSD.md` §11):

```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
service dsh_web start
```

### 4.3 ⚠️ Must use loopback (127.0.0.1:3080) + SSH tunnel, or the host RPC trust fence returns HTTP 403

The web UI **only listens on `127.0.0.1:3080`** (loopback). This is not a config switch — it's the harness's deliberate **confused-deputy / DNS-rebinding protection**: host-class RPCs (e.g. "pick workspace dir" `host.listDirectory`) require the request `Host` to be loopback, otherwise they return `HTTP 403` — **cannot be bypassed by config**.

- **On the box itself**, open `http://127.0.0.1:3080` directly.
- **Remote access only via SSH tunnel** (run on your local workstation):

```sh
ssh -L 3080:127.0.0.1:3080 workbuddy@192.168.1.5
# then open http://localhost:3080 in the browser
```

The tunnel fixes two things at once: loopback `Host` (no 403) + a secure context (native `crypto.randomUUID` available, avoiding `crypto.randomUUID is not a function`).

**If something's wrong**: if you open the UI via a reverse proxy / LAN IP / public domain, even with the web process healthy, `host.listDirectory` etc. will `HTTP 403`. Always switch to the SSH tunnel or local `localhost`. Don't use a LAN IP for directory/file operations.

### 4.4 `danger-full-access` escape hatch (troubleshooting only)

When the helper can't be installed, or you want one launch fully unconfined:

```sh
# Method 1: the launcher forwards DSH_PERMISSION_MODE
DSH_PERMISSION_MODE=danger-full-access sh freebsd/dsh-web-restart.sh restart

# Method 2: pick the danger-full-access permission preset in the harness UI
```

⚠️ This **disables jail isolation**; commands run directly on the host. Use only for troubleshooting or when the helper is truly unavailable — not as the常态 (normal state).

---

## 5. Verification (copy-paste to confirm success)

### 5.1 Runtime self-check: 10/10

The repo ships `freebsd/verify-sandbox.mjs`, which calls the **real** (built) local sandbox lib, generates argv the same way the web server does, spawns the setuid helper for real, and asserts the confinement facts.

```sh
cd /home/workbuddy/github/deepseek-harness
DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs
```

**Expected output (10/10)**:

```
PASS confine selects jail bin
PASS enforcement is full
PASS mode flag passed
PASS workspace flag passed
PASS read-only write denied (non-zero)
PASS denied file absent on host
PASS workspace-write write ok
PASS written file present on host
PASS cwd is /workspace
PASS no network resolution

== SUMMARY: PASS=10 FAIL=0 ==
```

What each line means:
1. `confine selects jail bin` — the harness selected `dsh-jail-run` (not fail-closed).
2. `enforcement is full` — backend claims full enforcement (read-only bind / workspace-write bind cover all promised file effects).
3. `mode flag passed` — argv carries `--mode read-only`.
4. `workspace flag passed` — argv carries `--workspace <root>`.
5. `read-only write denied` — under read-only, writing to `/workspace` is refused (EROFS, non-zero exit).
6. `denied file absent on host` — the refused write did **not** leak to the host workspace.
7. `workspace-write write ok` — under workspace-write the write succeeds.
8. `written file present on host` — the write actually landed on the host path (workspace rebind is correct).
9. `cwd is /workspace` — the command lands in `/workspace` inside the jail.
10. `no network resolution` — the jail **cannot** resolve domain names (no network by default).

> Note: on this box `verify-sandbox.mjs` returned **PASS=10 FAIL=0**, matching above.

### 5.2 e2e tests: 5/5

Integration test `packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts` asserts world effects, wrap shape, and the kernel's denial dialect via `confine()` + the real helper.

```sh
cd /home/workbuddy/github/deepseek-harness
pnpm vitest run --config vitest.e2e.config.ts packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts
```

**Expected output (5/5)**:

```
 Test Files  1 passed (1)
      Tests  5 passed (5)
```

> Note: on this box the e2e run was **5 passed (5)**. The test auto-skips on non-FreeBSD or when the helper is absent.

### 5.3 Zero `SANDBOX_UNAVAILABLE` in the web log

When the sandbox works, confined modes should all use the jail — no "no backend" errors.

```sh
grep -c SANDBOX_UNAVAILABLE /home/workbuddy/dsh_web.log
# expected: 0
```

Also confirm the web process is **not** running `danger-full-access` (unless you intended to):

```sh
ps -ww -o pid,command -U workbuddy | grep 'dsh:freebsd web' | grep -v grep
# expected: shows node ... pnpm dsh:freebsd web, WITHOUT DSH_PERMISSION_MODE=danger-full-access
```

**If something's wrong**: if `grep -c` is > 0, some commands failed closed because the sandbox was unavailable — go back to Chapter 3 and check the binary's setuid, path, and filesystem.

---

## 6. Troubleshooting table (symptom → cause → fix)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `SANDBOX_UNAVAILABLE`: `sandbox mode "..." is requested but no sandbox backend is usable` | `dsh-jail-run` missing / not setuid / `DSH_JAIL_RUN_BIN` points wrong | Back to Ch.3: (1) binary exists `ls -l /var/dsh-jail-run`; (2) perms `-rwsr-xr-x root wheel`; (3) `DSH_JAIL_RUN_BIN` correct in launcher/command. No web restart needed (each command re-execs the binary). |
| `Permission denied` on jail's `/tmp` | Old binary didn't `chmod 01777 /tmp` (fixed in the patched build) | **Reinstall the new build**: `cc ... && install -o root -g wheel -m 4755 dsh-jail-run /var/dsh-jail-run`. Current `/var/dsh-jail-run` (Aug 16 19:59 build) includes the /tmp-writable fix. |
| Shared lib missing like `libintl.so.8: not found` | `dsh-jail-run.c` nullfs-mounts the host `/var/run/ld-elf.so.hints` so the jail can find `/usr/local/lib` libs; if the **host** itself lacks the hints file or the lib, it breaks | On the host `ls -l /var/run/ld-elf.so.hints` should exist; if missing `service ldconfig restart` to rebuild. Missing lib → `pkg install` the package. |
| `Resource deadlock avoided` (EDEADLK) | nullfs **nested** mount (e.g. mounted `/usr` whole then `/usr/local` under it) | Known FreeBSD nullfs limit; the code avoids it by mounting only specific subdirs (`/usr/bin`, `/usr/local`, etc.), never `/usr` wholesale. If you edited `SYS_RO_MOUNTS` to nest, split them. |
| Jail can reach the network (`getent hosts github.com` returns) | `ip4`/`ip6` wrongly `inherit`, or `--network` was passed by mistake | Default `ip4=ip6=disable`. Check for `DSH_JAIL_NETWORK=1` or a stray `--network`; remove to restore no-network. |
| Missing shared lib (other than libintl) | Command depends on a lib outside the jail's read-only view | The read-only view already covers `/lib /usr/lib /usr/local` etc. If your command needs a lib in a non-standard path, add that path to `SYS_RO_MOUNTS` (recompile) or bundle it inside the workspace. |
| `command not found` / `exec ...: No such file or directory` (ENOENT) | Command not present inside the jail | Ensure the command lives in `/bin` / `/usr/bin` / `/usr/local/bin`; otherwise use an interpreter present in the jail, or extend `SYS_RO_MOUNTS`. |
| UI opens but "pick workspace dir" etc. fail with `HTTP 403` | Non-loopback `Host` (LAN IP / reverse proxy / public domain) | Always use the SSH tunnel or local `localhost` (4.3). This is the trust fence — **cannot be bypassed by config**. |
| Compile error `cannot find -ljail` | Missing jail lib/headers | Base system should have them; if stripped, `pkg install -y libjail` (and confirm `/usr/include/jail.h`). |
| After upgrading the binary, behavior didn't change | Forgot to re-`install` (only `cc` produced a new file, didn't replace the installed setuid copy) | Upgrades must `install -o root -g wheel -m 4755 dsh-jail-run <target>` (Ch.8). Usually no web restart needed. |

---

## 7. Security & threat model

**What the isolation boundary is (and isn't):**
- **Is**: strong least-privilege for the agent — only `workspace` is writable, everything else read-only, fresh `/tmp`, no network by default, restricted process view, rctl caps. A prompt-injected agent has a hard time reading host files outside the workspace or phoning out.
- **Is not**: a complete sandbox against **kernel exploit** abuse. If the jail's own kernel implementation has a privilege-escalation bug, the boundary breaks. It also doesn't protect secrets already present in the workspace (e.g. a `.env` you put there) — least-privilege ≠ secret management.

**setuid audit checklist (re-review on every upgrade/reinstall):**
1. `ls -l` confirms owner=root:wheel, mode `4755` (`-rwsr-xr-x`), **group/other not writable**.
2. Directory is non-user-writable and on a non-`nosuid` mount (Ch. 3.3).
3. Binary content comes from trusted source (`freebsd/dsh-jail-run.c`) — don't copy binaries from unknown sources.
4. Any source change recompiled+reinstalled must re-walk Chapter 3.

**What should NOT appear in logs:**
- No `dsh-jail-run:` runner-failure lines (those mean validation/mount/jail-create failure, exit 125) — if present, the helper itself errored; see Ch.6.
- No `SANDBOX_UNAVAILABLE` flooding (means the helper is unavailable and commands failed closed).
- Normal logs show jails created/removed, but should **never** show any command executing as uid 0 outside the jail.

**Upgrade/reinstall notes:**
- Must `install` as root to keep owner/perms correct.
- If the binary path was referenced from a user dir, confirm the new path is still non-nosuid and non-user-writable.
- After reinstall, immediately run `verify-sandbox.mjs` (5.1) to confirm 10/10.

---

## 8. Upgrade & reinstall

After editing `freebsd/dsh-jail-run.c`, recompile + reinstall the setuid binary as root.

### 8.1 Recompile + reinstall (needs root)

```sh
cd /home/workbuddy/github/deepseek-harness

# Normal install location (/usr writable)
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c
install -o root -g wheel -m 4755 dsh-jail-run /usr/local/sbin/dsh-jail-run

# Or this box's read-only /usr → install to /var
cc -O2 -Wall -ljail -o dsh-jail-run freebsd/dsh-jail-run.c
install -o root -g wheel -m 4755 dsh-jail-run /var/dsh-jail-run
```

### 8.2 Does the web service need a restart?

**Usually no.** Every dispatched command **re-`exec`s the `dsh-jail-run` binary** — it doesn't live inside the web process. After reinstalling, the next command uses the new binary; no web restart required.

The only time you must restart the web: you changed the web launcher (`dsh-web-run.sh`) or the harness source itself (then you must `pnpm run build` first; see `FREEBSD.md` §8).

### 8.3 Verify after upgrade

```sh
ls -l /var/dsh-jail-run        # confirm -rwsr-xr-x root wheel, mtime is just now
DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs   # expect 10/10
```

---

## Appendix: verified state (this box 192.168.1.5, FreeBSD 14.3-RELEASE-p7)

- `/var/dsh-jail-run`: `-rwsr-xr-x root wheel`, patched build (includes /tmp-writable fix).
- `node freebsd/verify-sandbox.mjs` → **PASS=10 FAIL=0**.
- e2e `freebsd-jail.e2e.ts` → **5 passed (5)**.
- web runs confined on `127.0.0.1:3080`; `SANDBOX_UNAVAILABLE` count in `dsh_web.log` is **0**.
- Commit `89a52eedda` pushed to github / gitea / gitcode.

Source files to read before editing docs (keep docs consistent with code):
- `freebsd/dsh-jail-run.c` — setuid-root jail runner.
- `freebsd/dsh-web-run.sh` — web launcher (no `danger-full-access`, sets `DSH_JAIL_RUN_BIN`).
- `packages/sandbox/sandbox-local/src/index.ts` — `freebsd-jail` runner TS wiring (`PLATFORM_CHAINS` / `probeRunner` / `runnerArgv` / `RUNNER_FAILURE_RULES`).
- `packages/sandbox/sandbox/src/index.ts` — FreeBSD branch of `sandboxUnavailableHint()`.
- `freebsd/verify-sandbox.mjs` — 10-point runtime self-check.
- `packages/sandbox/sandbox-local/tests/freebsd-jail.e2e.ts` — e2e tests.
