import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import type { SandboxPolicy } from '@deepseek-ai/dsh-sandbox'
import { LocalSandboxProvider } from '@deepseek-ai/dsh-sandbox-local'

/**
 * FreeBSD jail backend integration through `confine()` and a real `dsh-jail-run`
 * setuid helper (freebsd/dsh-jail-run.c). The helper is a sole candidate: its
 * presence is the probe, and its absence fails closed with SANDBOX_UNAVAILABLE
 * (see PROBE_SOLE_CANDIDATES in src/index.ts). Tests assert world effects, wrap
 * shape, and that the kernel denial matches the advertised dialect; consumer
 * coverage lives in dsh-bash-sandbox. Skips off-FreeBSD or when the setuid
 * helper is absent. HOME-based workspaces avoid the jail's ephemeral /tmp, so
 * workspace-write actually proves the workspace-root rebind.
 */

const jailBin = process.env.DSH_JAIL_RUN_BIN ?? '/usr/local/sbin/dsh-jail-run'
const freebsdJailUsable = process.platform === 'freebsd' && existsSync(jailBin)

let ctx: Context | undefined
const tempDirs: string[] = []
const tempFiles: string[] = []

afterEach(async () => {
  await ctx?.fiber.dispose()
  ctx = undefined
  await Promise.all(tempDirs.splice(0).map(dir => rm(dir, { recursive: true, force: true })))
  for (const file of tempFiles.splice(0)) rmSync(file, { force: true })
})

async function tempDir(base: string): Promise<string> {
  const dir = await mkdtemp(join(base, 'dsh-freebsd-e2e-'))
  tempDirs.push(dir)
  return dir
}

async function provider(): Promise<LocalSandboxProvider> {
  ctx = new Context()
  await ctx.plugin(LocalSandboxProvider, {})
  return ctx.sandbox as LocalSandboxProvider
}

/** Confine a shell command under `policy` and run it for real; returns the spawn result and the wrap's facts. */
function runConfined(sandbox: LocalSandboxProvider, command: string, policy: SandboxPolicy) {
  const confined = sandbox.confine(['bash', '-c', command], policy)
  const result = spawnSync(confined.argv[0] as string, confined.argv.slice(1), { timeout: 30_000, encoding: 'utf8' })
  return { result, confined }
}

describe.skipIf(!freebsdJailUsable)('sandbox-local: real FreeBSD jail confinement', () => {
  it('selects the freebsd-jail rung — full enforcement, EROFS dialect', async () => {
    const workdir = await tempDir(tmpdir())
    const sandbox = await provider()
    const confined = sandbox.confine(['true'], { mode: 'read-only', workspaceRoot: workdir })
    expect(confined.argv[0]).toBe(jailBin)
    expect(confined.argv).toContain('--workspace')
    expect(confined.argv).toContain(workdir)
    expect(confined.argv).toContain('--mode')
    expect(confined.argv).toContain('read-only')
    expect(confined.enforcement).toBe('full')
    expect(confined.denialSignatures).toEqual(['read-only file system', 'permission denied', 'operation not permitted'])
  })

  it('read-only denies a write — the file must NOT exist, and the kernel speaks the advertised dialect', async () => {
    const workdir = await tempDir(tmpdir())
    const sandbox = await provider()
    const { result } = runConfined(sandbox, 'echo hi > /workspace/denied.txt', { mode: 'read-only', workspaceRoot: workdir })
    expect(result.status).not.toBe(0)
    // The wrap's denialSignatures must be what the kernel actually prints.
    expect(result.stderr.toLowerCase()).toContain('read-only file system')
    expect(existsSync(join(workdir, 'denied.txt'))).toBe(false)
  })

  it('read-only keeps the tree readable/executable and the fresh /dev/null writable', async () => {
    const workdir = await tempDir(tmpdir())
    const sandbox = await provider()
    const { result } = runConfined(sandbox, 'ls /bin > /dev/null && test -x /bin/sh && echo dev-ok', { mode: 'read-only', workspaceRoot: workdir })
    expect(result.status).toBe(0)
    expect(result.stdout).toBe('dev-ok\n')
  })

  it('workspace-write lands a write inside the workspace root and still denies one beside it', async () => {
    const workdir = await tempDir(homedir())
    const sandbox = await provider()

    const inside = runConfined(sandbox, 'printf jail-ok > /workspace/allowed.txt', { mode: 'workspace-write', workspaceRoot: workdir })
    expect(inside.result.status).toBe(0)
    expect(readFileSync(join(workdir, 'allowed.txt'), 'utf8')).toBe('jail-ok')

    const denied = runConfined(sandbox, 'echo hi > /etc/denied.txt', { mode: 'workspace-write', workspaceRoot: workdir })
    expect(denied.result.status).not.toBe(0)
    // /etc is a read-only nullfs mount, so the kernel denies with EROFS — the
    // harness's advertised denial dialect for this backend.
    expect(denied.result.stderr.toLowerCase()).toContain('read-only file system')
  })

  it('workspace-write mounts an EPHEMERAL /tmp: the write succeeds inside, the host /tmp stays untouched', async () => {
    // The jail swaps in a fresh tmpfs at /tmp that dies with the jail, so a
    // write there never reaches the host /tmp — the strongest temp semantics.
    const workdir = await tempDir(homedir())
    const target = `/tmp/dsh-freebsd-e2e-ephemeral-${process.pid}.txt`
    tempFiles.push(target)
    const sandbox = await provider()
    const { result } = runConfined(sandbox, `printf tmp-ok > ${target} && cat ${target}`, { mode: 'workspace-write', workspaceRoot: workdir })
    expect(result.status).toBe(0)
    expect(result.stdout).toBe('tmp-ok')
    expect(existsSync(target)).toBe(false)
  })
})
