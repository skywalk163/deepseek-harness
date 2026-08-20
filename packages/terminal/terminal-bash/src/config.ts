/** Validated configuration for the local PTY backend. */

import z from '@deepseek-ai/schemastery'
import { existsSync } from 'node:fs'
import { resolvePwshPath } from '@deepseek-ai/dsh-pwsh-local'

/**
 * Resolve the default interactive shell for the current platform.
 *
 * FreeBSD does **not** ship bash in a default install -- its base interactive
 * shell is `/bin/sh`, an ash derivative. The terminal-bash backend, however,
 * depends on bash-specific behaviour:
 *   - `PROMPT_COMMAND` (set in `childEnvironment`) emits the per-prompt OSC
 *     `133;D;` marker the sanitizer uses to detect prompt boundaries and command
 *     exit status; ash does not honor `PROMPT_COMMAND`.
 *   - The default `shellArgs` (`--noprofile --norc -i`) are bash-only flags; ash
 *     treats `--noprofile`/`--norc` as script filenames and fails to start.
 * So on FreeBSD we resolve bash from its usual ports location and let
 * `validateConfig` fail loudly (with install instructions) when it is absent,
 * instead of producing a cryptic "PTY shell exited during startup" at spawn.
 */
function defaultShellPath(): string {
  if (process.platform === 'freebsd') {
    for (const candidate of ['/usr/local/bin/bash', '/bin/bash', '/usr/bin/bash']) {
      try {
        if (existsSync(candidate)) return candidate
      } catch {
        // ignore and try the next candidate
      }
    }
    return '/usr/local/bin/bash'
  }
  return '/bin/bash'
}

/** One supported interactive shell dialect. */
export type ShellDialect = 'bash' | 'pwsh'

/** Public plugin configuration. */
export interface Config {
  /** Backend registry type (default: `shell`). */
  backendType?: string
  /** Interactive shell dialect (default: `bash`); selects the argv/env/startup defaults. */
  shellDialect?: ShellDialect
  /** Interactive shell executable (default per dialect: `/bin/bash`, or the resolved pwsh). */
  shellPath?: string
  /** Shell arguments (default per dialect: bash `--noprofile --norc -i`, pwsh `-NoLogo -NoProfile`). */
  shellArgs?: string[]
  /** Terminal rows. */
  rows?: number
  /** Terminal columns. */
  cols?: number
  /** Maximum retained logical lines. */
  scrollbackLines?: number
  /** Maximum retained UTF-8 bytes. */
  scrollbackMaxBytes?: number
  /** Maximum bytes returned by one read or settled viewport. */
  maxReadBytes?: number
  /** Readiness polling interval. */
  pollIntervalMs?: number
  /** Delay before Linux exact syscall probes. */
  exactProbeAfterMs?: number
  /** Silence duration that yields `inferred_idle`. */
  idleSilenceMs?: number
  /**
   * Extra wait beyond `idleSilenceMs`, once a prompt marker was seen, for the shell to
   * regain the foreground before `inferred_idle` settles; at least one `pollIntervalMs`.
   */
  handoffGraceMs?: number
  /** Absolute send wait bound. */
  timeoutMs?: number
  /** Grace before teardown escalates to `SIGKILL`. */
  disposeGraceMs?: number
}

/** Configuration after Schemastery defaults and dialect resolution. */
export type ResolvedConfig = Omit<Required<Config>, 'shellDialect' | 'shellPath' | 'shellArgs'> & {
  shellDialect: ShellDialect
  shellPath: string
  shellArgs: string[]
}

/** Bash dialect default executable. */
export const DEFAULT_BASH_SHELL = '/bin/bash'
/** Bash dialect default arguments (interactive, profile-free). */
export const DEFAULT_BASH_ARGS = ['--noprofile', '--norc', '-i']
/** Pwsh dialect default arguments (interactive host, profile-free). */
export const DEFAULT_PWSH_ARGS = ['-NoLogo', '-NoProfile']

/**
 * Resolve the effective per-dialect shell specification. Defaulting is this
 * explicit step: an unset or empty `shellPath`/`shellArgs` selects the
 * dialect's defaults, while a non-empty explicit value always wins.
 * (Schemastery materializes an absent optional array as `[]`, so emptiness —
 * not just `undefined` — means "dialect default".)
 * @param config - Schemastery-resolved plugin configuration.
 * @returns the fully resolved configuration.
 */
export function resolveConfig(config: Config): ResolvedConfig {
  const shellDialect = config.shellDialect ?? 'bash'
  return {
    ...(config as Required<Config>),
    shellDialect,
    shellPath: config.shellPath !== undefined && config.shellPath.length > 0
      ? config.shellPath
      : (shellDialect === 'pwsh' ? resolvePwshPath() : defaultShellPath()),
    shellArgs: config.shellArgs !== undefined && config.shellArgs.length > 0
      ? config.shellArgs
      : (shellDialect === 'pwsh' ? DEFAULT_PWSH_ARGS : DEFAULT_BASH_ARGS),
  }
}

/** Schemastery config exposed by the plugin. */
export const Config: z<Config> = z.object({
  backendType: z.string().default('shell'),
  shellDialect: z.union(['bash', 'pwsh'] as const).default('bash'),
  shellPath: z.string().required(false),
  shellArgs: z.array(z.string()).required(false),
  rows: z.number().default(40),
  cols: z.number().default(160),
  scrollbackLines: z.number().default(10_000),
  scrollbackMaxBytes: z.number().default(4 * 1024 * 1024),
  maxReadBytes: z.number().default(256 * 1024),
  pollIntervalMs: z.number().default(50),
  exactProbeAfterMs: z.number().default(150),
  idleSilenceMs: z.number().default(3_000),
  handoffGraceMs: z.number().default(500),
  timeoutMs: z.number().default(30_000),
  disposeGraceMs: z.number().default(3_000),
})

/**
 * Assert every effective numeric config field is a positive safe integer and bounds compose.
 * @param config - Schemastery-resolved plugin configuration.
 * @returns Narrows the input to the fully resolved configuration.
 */
export function validateConfig(config: Config): asserts config is ResolvedConfig {
  const resolved = config as ResolvedConfig
  if (resolved.backendType.length === 0) throw new Error('terminal-bash: backendType must be non-empty')
  if (resolved.shellPath.length === 0) throw new Error('terminal-bash: shellPath must be non-empty')
  // FreeBSD does not ship bash by default (its base shell is /bin/sh, an ash
  // derivative). This backend requires bash: `PROMPT_COMMAND` (set in
  // index.ts `childEnvironment`) drives the per-prompt OSC 133;D; marker the
  // sanitizer relies on, and the default `shellArgs` (`--noprofile --norc -i`)
  // are bash-only flags. Fail here with install guidance rather than with a
  // cryptic "PTY shell exited during startup" at PTY spawn time.
  if (process.platform === 'freebsd') {
    if (!existsSync(resolved.shellPath)) {
      throw new Error(
        `terminal-bash: the configured shell "${resolved.shellPath}" does not exist. ` +
          'FreeBSD does not include bash in a default install. Install it first, e.g. ' +
          '`pkg install bash` (or from ports: `cd /usr/ports/shells/bash && make install clean`). ' +
          'If bash is installed at a non-standard path, set terminal-bash.shellPath to its absolute path.',
      )
    }
    const shellBase = resolved.shellPath.split('/').pop() ?? ''
    if (shellBase !== 'bash' && !shellBase.endsWith('bash')) {
      throw new Error(
        `terminal-bash: "${resolved.shellPath}" does not look like bash. ` +
          'The terminal-bash backend requires bash (it uses PROMPT_COMMAND and the ' +
          '--noprofile/--norc flags); the FreeBSD default /bin/sh (ash) is not supported. ' +
          'Install bash and point terminal-bash.shellPath at it.',
      )
    }
  }
  for (const [name, value] of Object.entries(resolved)) {
    if (typeof value === 'number' && (!Number.isSafeInteger(value) || value <= 0)) {
      throw new Error(`terminal-bash: ${name} must be a positive safe integer`)
    }
  }
  if (resolved.maxReadBytes > resolved.scrollbackMaxBytes) {
    throw new Error('terminal-bash: maxReadBytes must not exceed scrollbackMaxBytes')
  }
  if (resolved.handoffGraceMs < resolved.pollIntervalMs) {
    throw new Error('terminal-bash: handoffGraceMs must be at least pollIntervalMs so one readiness poll runs inside the grace window')
  }
}
