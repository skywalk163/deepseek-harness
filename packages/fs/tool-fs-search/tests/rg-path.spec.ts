/**
 * Failure-path tests for the lazy packaged-ripgrep resolution. The success
 * path (the real `@vscode/ripgrep` module) is exercised throughout
 * tools.spec.ts; here the module is mocked to throw at evaluation, proving a
 * missing or corrupt platform package (`--omit=optional`, partial install)
 * surfaces as a per-call `SEARCH_FAILED` — not a composition-load failure.
 *
 * FORK NOTE (FreeBSD port): `resolveRgPath` also falls back to a system `rg`
 * found on `PATH`, because `@vscode/ripgrep` ships no FreeBSD binary and
 * `pkg install ripgrep` is the only usable source. A test that means "nothing
 * usable exists" must therefore hide `PATH` too — otherwise any host that
 * happens to have ripgrep installed (all GitHub runners, and this repo's own
 * FreeBSD boxes) resolves successfully and these assertions never bite.
 */

import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { ToolExecution } from '@deepseek-ai/dsh-tools'
import { resolveRgPath, runRipgrep } from '@deepseek-ai/dsh-tool-fs-search'

// Any access to the mocked module's surface throws — the shape a missing
// platform package produces at module evaluation.
vi.mock('@vscode/ripgrep', () => new Proxy({}, {
  get() {
    throw new Error('platform package @vscode/ripgrep-win32-x64 is not installed')
  },
}))

describe('lazy packaged-ripgrep resolution', () => {
  beforeEach(() => {
    // Remove every usable candidate: the mocked platform package (above), the
    // env override, and the system `rg` on PATH.
    vi.stubEnv('PATH', '/nonexistent-dsh-ripgrep-test')
    vi.stubEnv('DSH_RIPGREP_PATH', '')
  })

  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it('fails the first search call with SEARCH_FAILED instead of failing module load', async () => {
    // The resolution rejects before any spawn, so no subprocess service is needed.
    const controller = new AbortController()
    const exec = { signal: controller.signal, name: 'glob', callId: ToolCallId('missing-platform-package') } as unknown as ToolExecution

    await expect(runRipgrep(new Context(), exec, 'glob', ['--files'], 1_000_000, 3_000, 64 * 1024))
      .rejects.toMatchObject({ name: 'SearchError', code: 'SEARCH_FAILED' })
  })

  it('does not memoize a failure, so a system rg installed later is picked up', async () => {
    // Nothing usable yet: both calls must reject. Upstream memoizes the first
    // rejection; the fork deliberately does not, so a `pkg install ripgrep`
    // after the harness booted is honoured by the very next search.
    await expect(resolveRgPath()).rejects.toThrow(/platform package/)
    await expect(resolveRgPath()).rejects.toThrow(/platform package/)

    const binDir = mkdtempSync(join(tmpdir(), 'dsh-rg-'))
    try {
      const fakeRg = join(binDir, 'rg')
      writeFileSync(fakeRg, '#!/bin/sh\nexit 1\n')
      chmodSync(fakeRg, 0o755)
      vi.stubEnv('PATH', binDir)
      await expect(resolveRgPath()).resolves.toBe(fakeRg)
    } finally {
      rmSync(binDir, { recursive: true, force: true })
    }
  })
})
