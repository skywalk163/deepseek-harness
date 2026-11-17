import { closeSync, writeSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { ensureStandardStreams } from '../src/sharp.ts'

/**
 * The repair exists for the FreeBSD WebAssembly Sharp backend, whose Emscripten
 * runtime calls `fstatSync` on descriptors 0, 1, and 2 while it evaluates. A
 * descriptor that cannot be stat'ed makes that call throw `EBADF`, which the
 * runtime reports as an unhandled rejection and leaves the binding half
 * initialized. These cases close *stdin* only: it is the one standard
 * descriptor the test runner does not report through, so a repaired slot cannot
 * swallow the run's own output.
 */
describe('standard-descriptor repair', () => {
  it('leaves statable descriptors untouched', () => {
    expect(ensureStandardStreams()).toEqual([])
  })

  it('rebinds a closed stdin to /dev/null and reports it once', () => {
    closeSync(0)

    expect(ensureStandardStreams()).toEqual([0])
    // Idempotent: the rebound descriptor is statable, so nothing is repaired again.
    expect(ensureStandardStreams()).toEqual([])
  })

  it('keeps stdout usable when stdin had to be repaired', () => {
    closeSync(0)
    ensureStandardStreams()

    expect(() => writeSync(1, '')).not.toThrow()
  })
})
