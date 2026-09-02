# Agent Note: FreeBSD sandbox rung: the boxrun jail runner

Status: implemented

English | [中文](2026-08-16-freebsd-boxrun-jail-sandbox.zh.md)

## Problem

The original [sandbox decision](2026-07-06-sandbox.md) left `PLATFORM_CHAINS.freebsd` empty, so FreeBSD shipped without a confining backend and every confined mode failed closed with `SANDBOX_UNAVAILABLE` — the [FreeBSD runbook](../../../../FREEBSD.md) could only operate unconfined via `DSH_PERMISSION_MODE=danger-full-access`. FreeBSD has no bwrap, Landlock, Seatbelt, or Windows restricted-token runner; the jail(8) machinery is the native answer, but creating jails requires root and the service runs as an unprivileged user. The rung must govern the two file-effect modes — `read-only` (no writable root) and `workspace-write` (workspace root plus a backend-defined temp area) — with parity to the Linux bwrap profile, including the workspace as the command's working directory.

## Decision

Adopt **boxrun** ([`sysutils/boxrun`](https://gitlab.com/tgasiba/boxrun), MIT, single C file) as the `freebsd` rung: a bwrap-equivalent that builds jails + nullfs mounts + procctl hardening and is installed **setuid-root** (`-m 4755`), which is precisely what lets the unprivileged service user create jails — boxrun drops to the caller's identity before exec'ing the confined command. Its CLI mirrors bwrap (`--ro-bind`/`--rw-bind`/`--tmpfs`/`--dev`/`--proc`/`--all`), so the provider integrates exactly like the seatbelt rung: sole candidate selected unprobed, `STATIC_ENFORCEMENT.full` (nullfs read-only mounts govern every promised write effect by construction), denial dialect `read-only file system` (EROFS, identical to bwrap), and a signature-only runner-failure rule on the `boxrun: ` err(3) prefix.

The profile (`boxrunProfileArgs`) maps the modes to mounts: `--all` (system + `/usr/local` + `/etc` + `/var` + all library trees, read-only), `--dev` (ruleset-4 devfs), `--proc`, `/home` read-only in both modes (so `~/.gitconfig`/`~/.npmrc` reads match bwrap's read-only whole-tree mount), `workspace-write` adds `--tmpfs /tmp` and a `--rw-bind` of the workspace root (nullfs stacking over the read-only `/home`, the same shape as bwrap's workspace bind over read-only `/`), `read-only` keeps `/tmp` and the workspace read-only. Three boxrun defaults are pinned for parity: `--net` (network stays outside the sandbox vocabulary, like every other backend), `--inherit-env` (boxrun's default `--clearenv` would strip PATH/HOME and the terminal's `PROMPT_COMMAND` markers), and `--chdir <workspace>` (boxrun's default `/` would discard the harness working directory).

Two upstream defects are carried as the repo patch [`patches/boxrun-dsh.patch`](../../../../patches/boxrun-dsh.patch): boxrun 0.4.3 hardcodes `chdir("/")` inside the jail (the patch adds `--chdir DIR`), and it refuses to run at all when `kern.racct.enable=0` even with no `--limit-*` flags (the patch turns that hard check into a warning; `--limit-*` still fail closed through `apply_rctl_rule`). The racct warning shares the fatal `boxrun: ` prefix, so the runner-failure rule excludes it as an `informationalLines` exact line (`BOXRUN_RCTL_WARNING`) — without that, every non-zero command exit on a racct-disabled box would be misclassified as a runner failure. The runner resolves to `/usr/local/sbin/boxrun` (not on a normal user's PATH) with a PATH fallback. A workspace root of `/` cannot be bound (boxrun forbids mounting `/`) and is omitted from the profile; `--chdir /` then starts at the jail root, which is that workspace's own semantics.

## Alternatives considered

- **Hand-rolled native jail runner** (a C wrapper over `jail(8)` + `mount_nullfs`, mirroring the landlock-run launcher): full control but re-implements everything boxrun already does — mount ordering, devfs rulesets, privilege drop, orphan reaping, death signals, cleanup on crash — with a larger security surface to get right. boxrun is MIT, single-file, and FreeBSD-official (`sysutils/boxrun`); the only delta we carry is the two-line `--chdir`/racct patch.
- **Capsicum (`cap_enter`/`cap_rights_limit`) native runner**: capability mode restricts already-open file descriptors, not paths — it cannot express "read-only filesystem plus a writable workspace" for an arbitrary `bash -c` without per-path FD grants, and it requires the confined program to cooperate. Rejected on semantic mismatch.
- **ZFS snapshot + clone per command**: strong isolation but heavyweight (a snapshot/clone per confined run), ZFS-only, and needs root for every run rather than once at install.
- **`fusefs-sandboxfs`**: userspace FUSE without jail hardening — slower and weaker than kernel jails.
- **Chroot only**: no process/network isolation and trivially escapable by root; rejected as not a hard boundary.

## Consequences

FreeBSD runs the full sandbox vocabulary under default `workspace-write` with no environment override: `bash` one-shot commands and the persistent PTY terminal both spawn through the boxrun jail (the boxrun `PROC_PDEATHSIG_CTL` and `PROC_REAP_KILL` mirror bwrap's `--die-with-parent` lifetime, and the FreeBSD process-inspector already kills the jail'd process tree). Fail-closed is preserved: a missing, non-setuid, or broken boxrun yields `SANDBOX_UNAVAILABLE` at spawn/run, never an unconfined fallthrough. The whitelist read model is stricter than bwrap's read-only `/` — only the mounted directories are reachable (`/root`, `/opt`, `/compat`, sibling mounts are invisible) — a deliberate hardening that the runbook documents. `--limit-*` resource controls need `kern.racct.enable=1` (a boot-time tunable, left off by default). The `--chdir` patch must be re-applied across boxrun upgrades unless merged upstream.
