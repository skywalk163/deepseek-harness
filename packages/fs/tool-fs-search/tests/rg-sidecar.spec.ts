import { join, parse } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Packaged-ripgrep resolution order: the pkg sidecar beside the executable, the
 * Electron ASAR rewrite, and the plain dependency path in an ordinary Node
 * process.
 *
 * FORK NOTE (FreeBSD port): `resolveRgPath` also falls back to a system `rg`
 * found on `PATH`, because `@vscode/ripgrep` ships no FreeBSD binary and
 * `pkg install ripgrep` is the only usable source. That fallback sits AFTER the
 * packaged path, so it only takes over when the packaged path does not exist —
 * but it means these tests must hide `PATH`, or a host that happens to have
 * ripgrep installed resolves to `/usr/local/bin/rg` and the packaged-path
 * assertions never see the dependency.
 */

const { dependency, existsSync } = vi.hoisted(() => ({
  dependency: { rgPath: '/node_modules/@vscode/ripgrep/bin/rg' },
  existsSync: vi.fn(),
}))
const originalPlatform = process.platform
const originalExecPath = process.execPath
const originalRipgrepOverride = process.env.DSH_RIPGREP_PATH

vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>()
  return { ...actual, existsSync }
})

vi.mock('@vscode/ripgrep', () => ({ get rgPath() { return dependency.rgPath } }))

beforeEach(() => {
  vi.resetModules()
  existsSync.mockReset()
  dependency.rgPath = '/node_modules/@vscode/ripgrep/bin/rg'
  Reflect.deleteProperty(process, 'pkg')
  Reflect.deleteProperty(process.versions, 'electron')
  Reflect.defineProperty(process, 'platform', { configurable: true, enumerable: true, value: originalPlatform })
  process.execPath = originalExecPath
  // Remove every non-packaged candidate (see FORK NOTE above): the env override
  // and the system `rg` on PATH. The override must be ABSENT, not `''` — its
  // guard is `override !== undefined && existsSync(override)`, and this file
  // mocks existsSync, so an empty string would be accepted as a real override.
  vi.stubEnv('PATH', '/nonexistent-dsh-ripgrep-test')
  delete process.env.DSH_RIPGREP_PATH
})

afterEach(() => {
  vi.unstubAllEnvs()
  if (originalRipgrepOverride === undefined) delete process.env.DSH_RIPGREP_PATH
  else process.env.DSH_RIPGREP_PATH = originalRipgrepOverride
  Reflect.deleteProperty(process, 'pkg')
  Reflect.deleteProperty(process.versions, 'electron')
  Reflect.defineProperty(process, 'platform', { configurable: true, enumerable: true, value: originalPlatform })
  process.execPath = originalExecPath
})

describe('ripgrep resolution', () => {
  it('uses the native sidecar beside the current executable', async () => {
    Reflect.defineProperty(process, 'pkg', { configurable: true, value: {} })
    Reflect.defineProperty(process, 'platform', { configurable: true, enumerable: true, value: 'linux' })
    process.execPath = '/runtime/dsh'
    existsSync.mockReturnValue(true)
    const sidecar = '/runtime/dsh-rg'
    const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')

    await expect(resolveRgPath()).resolves.toBe(sidecar)
    expect(existsSync).toHaveBeenCalledWith(sidecar)
  })

  it('uses a conventional executable name for the Windows ripgrep sidecar', async () => {
    Reflect.defineProperty(process, 'pkg', { configurable: true, value: {} })
    Reflect.defineProperty(process, 'platform', { configurable: true, enumerable: true, value: 'win32' })
    process.execPath = 'C:\\runtime\\deepseek-harness-sdk-runtime-win-x64.exe'
    existsSync.mockReturnValue(true)
    const sidecar = 'C:\\runtime\\deepseek-harness-sdk-runtime-win-x64-rg.exe'
    const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')

    await expect(resolveRgPath()).resolves.toBe(sidecar)
    expect(existsSync).toHaveBeenCalledWith(sidecar)
  })

  it('uses the dependency binary in an ordinary Node process', async () => {
    existsSync.mockReturnValue(true)
    const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')

    await expect(resolveRgPath()).resolves.toBe(dependency.rgPath)
    // FORK NOTE: upstream forbade any probe here; the fork deliberately checks
    // the packaged path before trusting it, so a missing FreeBSD platform
    // package falls through to the system rg instead of returning a dead path.
    expect(existsSync).toHaveBeenCalledWith(dependency.rgPath)
  })

  it('uses the dependency binary when a packaged runtime has no sidecar', async () => {
    Reflect.defineProperty(process, 'pkg', { configurable: true, value: {} })
    existsSync.mockReturnValue(false)
    const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')

    await expect(resolveRgPath()).resolves.toBe(dependency.rgPath)
    const executable = parse(process.execPath)
    const sidecar = process.platform === 'win32'
      ? join(executable.dir, `${executable.name}-rg.exe`)
      : `${process.execPath}-rg`
    expect(existsSync).toHaveBeenCalledWith(sidecar)
  })

  it('uses the unpacked executable path for an Electron ASAR dependency', async () => {
    Reflect.defineProperty(process.versions, 'electron', { configurable: true, value: '44.0.0' })
    dependency.rgPath = '/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@vscode/ripgrep/bin/rg'
    const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')

    await expect(resolveRgPath()).resolves.toBe(
      '/Applications/DeepSeek Harness.app/Contents/Resources/app.asar.unpacked/dsh/node_modules/@vscode/ripgrep/bin/rg',
    )
  })
})
