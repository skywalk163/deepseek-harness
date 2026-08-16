feat(freebsd): add FreeBSD jail sandbox backend for code/mini/standard

Replace the fail-closed SANDBOX_UNAVAILABLE behaviour on FreeBSD with a real
jail isolation backend driven by the setuid helper freebsd/dsh-jail-run.c.

- sandbox-local: wire 'freebsd-jail' into PLATFORM_CHAINS, STATIC_ENFORCEMENT,
  DENIAL_SIGNATURES and RUNNER_FAILURE_RULES; add runnerArgv + probeRunner
  cases and a PROBE_SOLE_CANDIDATES fail-closed path when the helper is absent.
- sandbox: rework the FreeBSD sandboxUnavailableHint to point at the
  dsh-jail-run install + FREEBSD.md instead of only danger-full-access.
- freebsd/dsh-jail-run.c: setuid-root jail runner — workspace RO/RW, read-only
  system view, restricted devfs (ruleset 4), ephemeral tmpfs /tmp (1777),
  no network by default, rctl/racct limits, drops to the caller uid/gid.
- freebsd/dsh-web-run.sh: default to confined mode (no forced
  danger-full-access); point DSH_JAIL_RUN_BIN at the installed helper.
- tests: add freebsd-jail.e2e.ts (skips when the helper is absent).
- docs: FREEBSD.md / FREEBSD.zh.md — new jail-enablement section; fix the
  now-false "danger-full-access is mandatory on FreeBSD" claim.

Verified: 10/10 standalone confinement checks; e2e 4/5 against the prior
binary (the remaining /tmp-writability case is fixed by the chmod 1777 in
this commit and requires a setuid reinstall of the helper).
