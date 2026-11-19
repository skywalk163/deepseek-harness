# Post-mortem 0005: a bad stdio descriptor crashed the service on every image read

English | [中文](0005-bad-stdio-descriptor-crashed-on-image-read.zh.md)

Status: resolved

## Executive summary

On FreeBSD, `sharp` has no native binary and resolves to a WebAssembly build whose Emscripten runtime calls `fstatSync` on descriptors 0, 1, and 2 while the module evaluates. When stdin exists but cannot be stat'ed — the state `fstat(1)` prints as `bad`, which is what `revoke(2)` leaves behind when a controlling session ends — that call throws `EBADF`, and the runtime reports it as an unhandled rejection from its own async startup rather than as a catchable load error. `require('sharp')` therefore "succeeds" with a half-initialized binding: the first raster operation failed with `sharp.libvipsVersion is not a function`, and the stray rejection tripped the fail-loud handler, exiting the whole web service. Reading one image, or merely pasting one, could take the service down. Every safety net missed it because the dependency has no FreeBSD-native test lane, the failure arrives through a channel no test observed, and the trigger is a descriptor state that only a service environment produces. The loader now repairs descriptors 0-2 before the load, the service is started with an explicit `</dev/null`, and a sibling defect in the service scripts (FreeBSD `pgrep`/`pkill` ancestor exclusion) was found and fixed alongside.

## Summary

The service ran indefinitely and served every non-image tool correctly. The first `read_image` call in any session failed with `Error: sharp.libvipsVersion is not a function`, and within seconds `dsh_web.log` gained `dsh: fatal load failure: ErrnoError { name: 'ErrnoError', errno: 8 }` and the process exited. Because the service is a supervised `daemon(8)` child, it did not restart itself; the operator had to restart it by hand, and the failure recurred on the next image read.

The trigger was independent of the image: a 1440x900 screenshot, a 64x64 fixture, and a pasted image all reproduced it. Two defects combined. The first is platform-shaped: on FreeBSD `sharp` resolves through `@img/sharp-freebsd-wasm32` to `@img/sharp-wasm32`, and that Emscripten module builds its `/dev/stdin`, `/dev/stdout`, and `/dev/stderr` streams by calling `fstatSync(0|1|2)` during module evaluation. The second is environmental: the live service process held descriptor 0 in a state `fstat(1)` prints as `bad` — present in the table but not statable.

The two together turn a load into a process exit. `fstatSync` throws `EBADF`; the runtime's async startup reports that as an unhandled rejection instead of raising a load error, so the module is left half initialized and `require('sharp')` returns a callable constructor whose binding lacks `libvipsVersion`. `installFailLoud` then does exactly its job on the stray `ErrnoError` rejection: one labelled stderr line and `exit(1)`.

## Impact

Every image-reading path failed, and each failure ended the service. `read_image` is the model-facing tool for screenshots, so a session doing UI verification lost its harness mid-turn; unrelated concurrent sessions died with it because the service is one process. The failure was also self-concealing: the tool-level error named a `sharp` internal, while the process-level cause was a FreeBSD descriptor state, so the message pointed at the wrong subsystem.

No data was lost and no confinement was weakened. Session transcripts survived because the store writes durably before the tool returns; the impact was availability and diagnostic integrity.

## Timeline

- The service had been restarted 48 times across the log's history, with three earlier `fatal load failure: ErrnoError { errno: 8 }` lines that had no recorded explanation.
- A session reading a Wine screenshot produced `sharp.libvipsVersion is not a function`, then the fatal `ErrnoError` line; the same signature appeared in two other sessions, all after `read_image`.
- `require('sharp')` was verified healthy on the host in a fresh process, which is why the dependency initially looked innocent.
- `fstat -p <service pid>` showed `0 - - bad -` on the live process while it still listened on `:3080`; `fstat -p` on a freshly spawned process showed `/dev/null`.
- Closing descriptors 0-2 before the first load reproduced the production pair exactly: `RAW THREW sharp.libvipsVersion is not a function` plus `UNHANDLED ErrnoError errno=8`.
- `revoke(2)` on a process's own pty produced the same `0:EBADF 1:EBADF 2:EBADF` line, confirming the descriptor state and not merely "closed" is what matters.
- While fixing the stop path, `pgrep`/`pkill` were found to have a second, independent defect: FreeBSD excludes ancestors by default, and `-a` overshoots by matching shells that merely mention the service string.

## Root cause

The persistence-neutral fact is that `sharp`'s FreeBSD backend is a WebAssembly module, so it observes process state that a native binding would not: it stats the standard descriptors at load. The repository treated `sharp` as a lazy, pure raster dependency (`createLazyRequire` in [`sharp.ts`](../../packages/attachment/attachment-local/src/sharp.ts)), which is accurate for every platform with a native binary and wrong on FreeBSD.

The failure channel is what made it fatal. An unhandled rejection from a dependency's internal async startup is indistinguishable, at the handler, from a boot failure in dsh's own code — `installFailLoud` cannot know that the rejection came from Emscripten's `FS.init`. Treating every stray rejection as fatal is the correct policy for this repository; the defect is that image loading could produce one at all.

Why each net missed it:

- **No FreeBSD-native test lane.** CI and the development machines resolve `sharp` to a native binary, which never stats the standard descriptors, so the failure cannot occur there. The FreeBSD assets are exercised through a wasm path that only exists on that platform.
- **The tests close no descriptors.** No spec in [`packages/attachment/attachment-local/tests/`](../../packages/attachment/attachment-local/tests/) manipulates the descriptor table, so the precondition was never constructed.
- **The trigger needs a service environment.** An interactive shell's descriptors are healthy; `daemon(8)` plus a revoked or unreachable stdin is what produces `bad`. Manual runs looked fine, which is the classic shape of an environment-dependent defect.
- **The tool error named the wrong subsystem.** `sharp.libvipsVersion is not a function` describes a half-initialized binding, not a descriptor; nothing in that message points at `fstat`.

## Guardrails added

- [`ensureStandardStreams()`](../../packages/attachment/attachment-local/src/sharp.ts) stats descriptors 0-2 and rebinds an unusable slot to `/dev/null` (close then open, so the lowest-free-descriptor rule refills the same number). `requireSharp()` runs it before the load and refuses to load when a descriptor cannot be restored, converting a fatal rejection into a catchable error.
- [`LocalAttachmentStore`](../../packages/attachment/attachment-local/src/index.ts) runs the same repair in its constructor, so it happens at mount time and covers the paste path rather than the first raster operation.
- [`standard-streams.spec.ts`](../../packages/attachment/attachment-local/tests/standard-streams.spec.ts) pins the repair, including idempotence.
- [`dsh_web.rcd`](../../freebsd/dsh_web.rcd) and [`dsh-web-restart.sh`](../../freebsd/dsh-web-restart.sh) start the service with an explicit `</dev/null`, so a supervised process never inherits a bad descriptor 0.
- [`verify-service-match.sh`](../../freebsd/verify-service-match.sh) asserts the service matcher ignores non-`node` processes and that `status` reports the real state.
- The service scripts and the ports template [`dsh_web.in`](../../dsh-freebsd-port/devel/deepseek-harness/files/dsh_web.in) identify the harness by exact argv and signal explicit PIDs, replacing `pgrep -f` / `pkill -f`, which both misses ancestors and can kill unrelated shells.
- [FreeBSD startup troubleshooting](../../freebsd-startup-troubleshooting.md) records the symptom, the descriptor semantics, and the reproduction.

## Lessons

- A lazy dependency contract is a claim about when a module runs, not about what it touches. A WebAssembly backend can observe process state at load that a native one ignores, so the platform's actual binding decides the contract.
- "Present but not statable" is a third descriptor state beside open and closed. `fstat` distinguishes it, and recovery has to close the slot before reopening or the new descriptor lands elsewhere.
- A dependency that reports startup failure through an unhandled rejection can crash any process with a fail-loud handler, no matter how unrelated the failing call is to the reject site.
- An environment-dependent defect needs an environment-shaped reproduction. Reproducing this one required closing real descriptors and revoking a terminal, not a mock.
- FreeBSD's `pgrep`/`pkill` need `-a` to see ancestors, but for anything that *signals* processes, `-a` plus a substring is still wrong: match the exact argv and signal explicit PIDs.
