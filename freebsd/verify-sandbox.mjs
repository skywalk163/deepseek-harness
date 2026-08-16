// Standalone runtime check for the FreeBSD jail sandbox backend.
// Exercises the REAL built lib (@deepseek-ai/dsh-sandbox-local -> lib/index.js)
// the way the dsh web server uses it, then spawns the setuid helper and
// asserts the confinement facts. Run from the repo root:
//   DSH_JAIL_RUN_BIN=/var/dsh-jail-run node freebsd/verify-sandbox.mjs
import { Context } from '@deepseek-ai/cordis'
import { LocalSandboxProvider } from '@deepseek-ai/dsh-sandbox-local'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, existsSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const bin = process.env.DSH_JAIL_RUN_BIN ?? '/usr/local/sbin/dsh-jail-run'
let pass = 0
let fail = 0
function ck(name, cond, extra = '') {
  if (cond) { pass++; console.log('PASS', name) }
  else { fail++; console.log('FAIL', name, extra) }
}

async function main() {
  const ctx = new Context()
  await ctx.plugin(LocalSandboxProvider, {})
  const sandbox = ctx.sandbox

  // 1. confine() selects the freebsd-jail backend and passes the policy through.
  //    (/tmp is used only as a throwaway workspaceRoot to inspect argv shape.)
  const probe = sandbox.confine(['true'], { mode: 'read-only', workspaceRoot: '/tmp' })
  ck('confine selects jail bin', probe.argv[0] === bin, JSON.stringify(probe.argv))
  ck('enforcement is full', probe.enforcement === 'full')
  ck('mode flag passed', probe.argv.includes('--mode') && probe.argv.includes('read-only'))
  ck('workspace flag passed', probe.argv.includes('--workspace') && probe.argv.includes('/tmp'))

  // Real workspace is a fresh host dir; it becomes /workspace inside the jail.
  const work = mkdtempSync(join(tmpdir(), 'dsh-ver-'))

  // 2. read-only denies a /workspace write (EROFS -> non-zero), and nothing
  //    leaks to the host workspace.
  const denied = sandbox.confine(['bash', '-c', 'echo hi > /workspace/denied.txt'], { mode: 'read-only', workspaceRoot: work })
  const deniedRun = spawnSync(denied.argv[0], denied.argv.slice(1), { encoding: 'utf8' })
  ck('read-only write denied (non-zero)', deniedRun.status !== 0, `status=${deniedRun.status} stderr=${deniedRun.stderr.trim()}`)
  ck('denied file absent on host', !existsSync(join(work, 'denied.txt')))

  // 3. workspace-write allows a /workspace write; it lands on the host path.
  const wrote = sandbox.confine(['bash', '-c', 'printf OK > /workspace/ok.txt'], { mode: 'workspace-write', workspaceRoot: work })
  const wroteRun = spawnSync(wrote.argv[0], wrote.argv.slice(1), { encoding: 'utf8' })
  ck('workspace-write write ok', wroteRun.status === 0, wroteRun.stderr)
  ck('written file present on host', existsSync(join(work, 'ok.txt')) && readFileSync(join(work, 'ok.txt'), 'utf8') === 'OK')

  // 4. the command lands in /workspace inside the jail.
  const cwd = sandbox.confine(['bash', '-c', 'pwd'], { mode: 'read-only', workspaceRoot: work })
  const cwdr = spawnSync(cwd.argv[0], cwd.argv.slice(1), { encoding: 'utf8' })
  ck('cwd is /workspace', cwdr.stdout.trim() === '/workspace', JSON.stringify(cwdr.stdout))

  // 5. no network inside the jail.
  const net = sandbox.confine(['bash', '-c', 'getent hosts github.com || true'], { mode: 'read-only', workspaceRoot: work })
  const netr = spawnSync(net.argv[0], net.argv.slice(1), { encoding: 'utf8' })
  ck('no network resolution', !/github\.com/m.test(netr.stdout), netr.stdout)

  rmSync(work, { recursive: true, force: true })
  await ctx.fiber.dispose()
  console.log(`\n== SUMMARY: PASS=${pass} FAIL=${fail} ==`)
  process.exit(fail === 0 ? 0 : 1)
}

main().catch((e) => { console.error(e); process.exit(2) })
