/**
 * Process-realm lazy access to Sharp's CommonJS-compatible entry, with the
 * standard-descriptor repair its FreeBSD WebAssembly backend needs first.
 *
 * On FreeBSD, sharp resolves to `@img/sharp-freebsd-wasm32`. Its Emscripten
 * runtime builds the `/dev/stdin`, `/dev/stdout`, and `/dev/stderr` streams by
 * calling `fstatSync` on descriptors 0, 1, and 2 while the module evaluates,
 * and a descriptor that cannot be stat'ed makes that call throw `EBADF`. The
 * failure arrives as an unhandled rejection (`ErrnoError`, errno 8) from the
 * runtime's own async startup rather than as a thrown load error, so the module
 * is left half initialized — the first raster operation then fails with
 * `sharp.libvipsVersion is not a function` — and the harness treats the stray
 * rejection as a fatal boot failure and exits. That is how reading one image
 * could take the whole web service down.
 *
 * Repairing the three standard descriptors before the first load keeps that
 * startup working. Because a runtime that already started unstatable cannot be
 * repaired from JavaScript, the load is refused outright when a descriptor
 * still cannot be stat'ed after the repair: refusing costs one clear tool error
 * instead of a cached broken binding and a fatal process exit.
 * @module @deepseek-ai/dsh-attachment-local/src/sharp
 */

import { closeSync, fstatSync, openSync } from 'node:fs'
import type sharp from 'sharp'
import { createLazyRequire } from '@deepseek-ai/dsh-lazy-require'

/**
 * Whether one standard descriptor can be stat'ed, which is exactly what Sharp's
 * WebAssembly runtime requires of it. An absent descriptor is equally unusable,
 * so both states take the same repair path.
 * @param fd - standard descriptor number (0, 1, or 2).
 * @returns whether `fstatSync` accepts the descriptor.
 */
function isStatable(fd: number): boolean {
  try {
    fstatSync(fd)
    return true
  } catch {
    return false
  }
}

/**
 * Rebind one unusable standard descriptor to `/dev/null`. The original is
 * closed first so `openSync`'s lowest-free-descriptor rule refills that exact
 * slot; stdin is opened read-only and the output descriptors are opened for
 * append, so a repaired stdout or stderr silently discards writes.
 * @param fd - standard descriptor number to restore.
 * @returns whether the descriptor is statable afterwards.
 */
function restoreStandardStream(fd: number): boolean {
  try {
    closeSync(fd)
  } catch {
    // An absent descriptor needs no close; a close that fails for any other
    // reason leaves the slot occupied, which the reopen below reports.
  }
  try {
    const opened = openSync('/dev/null', fd === 0 ? 'r' : 'a')
    if (opened === fd) return true
    closeSync(opened)
  } catch {
    // Fall through to the caller's refusal.
  }
  return false
}

/**
 * Ensure descriptors 0, 1, and 2 can all be stat'ed, which is the precondition
 * for loading Sharp's FreeBSD WebAssembly backend.
 * @returns the repaired descriptor numbers in ascending order.
 * @throws Error naming every descriptor that could not be restored.
 */
export function ensureStandardStreams(): number[] {
  const repaired: number[] = []
  const unrecoverable: number[] = []
  for (const fd of [0, 1, 2]) {
    if (isStatable(fd)) continue
    if (restoreStandardStream(fd)) repaired.push(fd)
    else unrecoverable.push(fd)
  }
  if (unrecoverable.length > 0) {
    throw new Error(
      `standard descriptor${unrecoverable.length === 1 ? '' : 's'} ${unrecoverable.join(', ')} cannot be stat'ed or rebound to /dev/null`,
    )
  }
  return repaired
}

/** Load Sharp itself; {@link requireSharp} owns the descriptor repair around it. */
const loadSharp = createLazyRequire<typeof sharp>('sharp', import.meta.url)

/**
 * Load Sharp once for this process, repairing the standard descriptors first.
 *
 * The repair precedes the load because the WebAssembly runtime reads those
 * descriptors during module evaluation, and the load is skipped entirely when a
 * descriptor stays unusable: an already-broken runtime would report the failure
 * as an unhandled rejection rather than a catchable error.
 * @returns the callable Sharp constructor.
 * @throws Error when the standard descriptors cannot be made statable.
 */
export function requireSharp(): typeof sharp {
  ensureStandardStreams()
  return loadSharp()
}
