/** Packaged ripgrep resolution and subprocess execution, independent of tool or Remote consumers. */
import { existsSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { join, parse } from 'node:path'
import type { SubprocessHandle, SubprocessOutcome, SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'

/**
 * The ripgrep binary path, resolved at each call (not memoized) so that a
 * system `rg` installed after the process started is picked up on the very
 * next search without having to restart the harness.
 *
 * A single-file runtime uses the executable's `-rg` sidecar because a native
 * helper cannot be spawned from pkg's virtual filesystem. Node-mode builds
 * fall back to the platform package selected by `@vscode/ripgrep`. Resolving
 * at the call boundary keeps a missing or corrupt binary at the first search
 * call as `SEARCH_FAILED`, rather than failing the Loader composition.
 *
 * FORK NOTE (FreeBSD port): upstream resolves lazily once per process and uses
 * no system fallback. Here `@vscode/ripgrep` ships no `freebsd-x64` package and
 * THROWS at import, so resolution order is:
 *   1. `DSH_RIPGREP_PATH` env override (explicit, e.g. a system ripgrep);
 *   2. a single-file runtime's `-rg` sidecar beside the executable;
 *   3. the packaged `@vscode/ripgrep` binary, only when the file exists;
 *   4. a system `rg` discovered on `PATH` (`pkg install ripgrep` on FreeBSD);
 *   5. the packaged path even if missing — lets spawn surface `SEARCH_FAILED`
 *      as before when nothing usable is available.
 *
 * Deliberately NOT memoized (upstream memoizes the first resolution): on FreeBSD
 * the usable binary is whatever `rg` the operator installed — `pkg install
 * ripgrep` is then picked up by the very next search, no harness restart.
 *
 * @returns the chosen binary's absolute path; the promise rejects when no
 *   platform package can be resolved and none of the fallbacks exist.
 */
export function resolveRgPath(): Promise<string> {
  return resolveRgPathUncached()
}

/**
 * Resolve the usable binary for this call. Checks the env override and single-
 * file sidecar first, then the packaged path, then a system `rg` (FreeBSD), and
 * finally the packaged path even if missing so spawn can surface SEARCH_FAILED.
 */
async function resolveRgPathUncached(): Promise<string> {
  const override = process.env.DSH_RIPGREP_PATH
  if (override !== undefined && existsSync(override)) return override
  const executable = parse(process.execPath)
  const executableSidecar = process.platform === 'win32'
    ? join(executable.dir, `${executable.name}-rg.exe`)
    : `${process.execPath}-rg`
  if ('pkg' in process && existsSync(executableSidecar)) return executableSidecar
  let packaged: string | undefined
  try {
    packaged = await resolvePackagedRgPath()
  } catch {
    // No platform package for this platform (FreeBSD ships none) — fall through
    // to a system binary.
  }
  if (packaged !== undefined && existsSync(packaged)) return packaged
  try {
    const onPath = execSync('command -v rg', { encoding: 'utf-8' }).trim()
    if (onPath.length > 0) return onPath
  } catch {
    // No system rg on PATH.
  }
  if (packaged !== undefined) return packaged
  return resolvePackagedRgPath()
}

/** The `@vscode/ripgrep` platform binary, with upstream's Electron asar rewrite. */
async function resolvePackagedRgPath(): Promise<string> {
  const dependency = (await import('@vscode/ripgrep')).rgPath
  return process.versions.electron === undefined
    ? dependency
    : dependency.replace(/\.asar(?=[\\/])/u, '.asar.unpacked')
}

/**
 * Start packaged ripgrep with explicit subprocess settings. `spec.argv` contains
 * only rg arguments, without an executable. This function prepends the resolved
 * rg executable path and `--no-config`, so ambient configuration cannot enable a
 * preprocessor. The caller owns exit classification and process cleanup.
 * @param subprocess - the composed subprocess service.
 * @param spec - cwd, rg arguments (without the executable), stdio, signal and termination grace.
 * @returns the live subprocess handle; resolution and synchronous spawn failures reject.
 */
export async function spawnRipgrep(subprocess: Pick<SubprocessRuntime, 'spawn'>, spec: SubprocessSpawnSpec): Promise<SubprocessHandle> {
  const executable = await resolveRgPath()
  return subprocess.spawn({ ...spec, argv: [executable, '--no-config', ...spec.argv] })
}

/** Exit facts and whether the line consumer requested early termination. */
export interface RipgrepLinesResult {
  readonly outcome: SubprocessOutcome
  readonly stopped: boolean
}

/**
 * Read UTF-8 stdout records without retaining the complete output. A false
 * callback return terminates the process and suppresses remaining records.
 * Completion, callback failure and stream failure all await process quiescence;
 * provider failures reject. Exit codes and cancellation remain consumer-owned.
 * @param handle - an owned ripgrep process spawned with piped stdout.
 * Records are decoded as UTF-8, so bytes of a name that is not valid UTF-8
 * arrive replaced with U+FFFD.
 * @param separator - newline for text output, or NUL for file paths that may contain newlines.
 * @param onLine - synchronous record consumer; false requests early termination.
 * @returns exit facts after stdout and the managed process range settle.
 */
export async function readRipgrepLines(
  handle: SubprocessHandle,
  separator: '\n' | '\0',
  onLine: (line: string) => boolean,
): Promise<RipgrepLinesResult> {
  const stdout = handle.stdout
  if (stdout === undefined) {
    handle.terminate()
    await Promise.allSettled([handle.done, handle.waitForExit()])
    throw new Error('ripgrep requires piped stdout')
  }
  stdout.setEncoding('utf8')
  let stopped = false
  let completed = false
  const reading = (async () => {
    let pending = ''
    for await (const chunk of stdout as AsyncIterable<string>) {
      if (stopped) continue
      pending += chunk
      let end: number
      while ((end = pending.indexOf(separator)) !== -1) {
        const line = pending.slice(0, end)
        pending = pending.slice(end + 1)
        if (!onLine(line)) {
          stopped = true
          pending = ''
          handle.terminate()
          break
        }
      }
    }
    if (pending.length > 0 && !onLine(pending)) {
      stopped = true
      handle.terminate()
    }
  })()
  try {
    const [, outcome] = await Promise.all([reading, handle.done])
    completed = true
    return { outcome, stopped }
  } finally {
    if (!completed) {
      handle.terminate()
      stdout.destroy()
    }
    await Promise.allSettled([reading, handle.done])
    await handle.waitForExit()
  }
}
