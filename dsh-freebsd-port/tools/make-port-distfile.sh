#!/bin/sh
# make-port-distfile.sh — produce the deepseek-harness FreeBSD port distfile
# from a BUILT dsh checkout on FreeBSD.
#
# What it does:
#   1. preflight: the tree must be fully built (lib/, apps/web/dist, the
#      native/system freebsd-x64 addon) — run `pnpm run build` first;
#   2. `pnpm --filter @deepseek-ai/dsh deploy --legacy --prod` — a runtime
#      closure (hardlinked from the store). --legacy is required on pnpm 11
#      (see the inline note at the deploy call for why);
#   3. fixups: frontend dist, native addon, LICENSE / THIRD_PARTY_NOTICES /
#      the jail helper C source, junk pruning;
#   3b. reconcile: copy every @deepseek-ai/* workspace package that pnpm
#       deploy omits (it only installs static `dependencies`, but the harness
#       loads cordis plugins dynamically) — this is what makes `dsh` boot;
#   3c. dereference: pnpm deploy --legacy leaves workspace packages as symlinks
#       back into the build host's source checkout, which dangle on any other
#       machine — replace them with real copies so the distfile is portable;
#   4. smoke: boot the deployed tree on a scratch port with a scratch HOME
#      and require HTTP 200 on the token URL;
#   5. tar (ownership normalized to root:wheel) + emit the distinfo and
#      pkg-plist fragments.
#
# Outputs (in ${WORK}, default /home/workbuddy/dsh-port-dist):
#   deepseek-harness-<ver>-freebsd-amd64.tar.gz   the distfile
#   distinfo.fragment                             SHA256 + SIZE lines
#   pkg-plist.fragment                            file list for pkg-plist
#   smoke.log                                     boot log of the smoke run
#
# Usage:  sh make-port-distfile.sh [version]        (default 0.2.1a4)
# Env:    DSH_REPO (default /home/workbuddy/github/deepseek-harness)
#         DSH_WORK (default /home/workbuddy/dsh-port-dist — MUST live on the
#                  same filesystem as the pnpm store, otherwise pnpm cannot
#                  hardlink and silently re-downloads the world)
#         DSH_SMOKE_PORT (default 3999)
#
# Memory guard: the smoke boots a node process. On a busy box it is skipped
# (loudly) when free RAM is below DSH_MIN_FREE_MB (default 1500).

set -u

# Launch modes. `ssh_run.py --file` runs the uploaded script with no
# arguments, so: no args (or `launch`) re-execs detached — a long chain over
# one SSH channel dies of SIGPIPE the moment the local side times out.
#   sh make-port-distfile.sh                  -> detached, default version
#   sh make-port-distfile.sh launch 0.2.1a5   -> detached, explicit version
#   sh make-port-distfile.sh 0.2.1a5          -> foreground, explicit version
if [ $# -eq 0 ] || [ "${1:-}" = "launch" ]; then
  LOG="${DSH_LOG:-/tmp/mkdist.log}"
  nohup sh "$0" __run "${2:-0.2.1a4}" > "${LOG}" 2>&1 &
  echo "launched (pid $!); follow: tail -f ${LOG}"
  exit 0
fi
if [ "${1:-}" = "__run" ]; then
  shift
fi

VER="${1:-0.2.1a4}"
ARCH=amd64
DISTNAME="deepseek-harness-${VER}-freebsd-${ARCH}"
REPO="${DSH_REPO:-/home/workbuddy/github/deepseek-harness}"
WORK="${DSH_WORK:-/home/workbuddy/dsh-port-dist}"
STAGE="${WORK}/${DISTNAME}"
SMOKE_PORT="${DSH_SMOKE_PORT:-3999}"
MIN_FREE_MB="${DSH_MIN_FREE_MB:-1500}"

log() { echo "== $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# www/node24 provides the plain `node` binary; keep a defensive fallback.
NODE_BIN=node
command -v node >/dev/null 2>&1 || NODE_BIN=node24
command -v "$NODE_BIN" >/dev/null 2>&1 || die "node not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

[ -d "${REPO}/.git" ] || die "repo not found at ${REPO} (set DSH_REPO)"
# A previous run's stage is hardlinked from the pnpm store and inherits its
# file flags (`ls -lo` shows `uarch`): rm then fails with EPERM ("Operation
# not permitted") even for the owner, and a leftover stage makes the next
# deploy fail with ERR_PNPM_DEPLOY_DIR_NOT_EMPTY. Clear flags + write bits
# first. (The distfile itself is unaffected — tar/cpio do not store fflags.)
clean_stage() {
  chflags -R 0 "$1" 2>/dev/null || true
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1"
}
clean_stage "${WORK}"
mkdir -p "${WORK}"

export PATH="/home/workbuddy/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:${PATH}"

log "preflight: build artifacts"
for f in "${REPO}/apps/cli/lib/bin.js" \
         "${REPO}/apps/web/dist/index.html" \
         "${REPO}/native/system/packages/freebsd-x64/bin/system.node"; do
  [ -e "$f" ] || die "missing build artifact: $f — run 'pnpm run build' in ${REPO} first"
done
command -v pnpm >/dev/null || die "pnpm not on PATH"
echo "  node: $("$NODE_BIN" --version)   pnpm: $(pnpm --version)"

log "deploy: pnpm --filter @deepseek-ai/dsh deploy --legacy --prod"
cd "${REPO}" || die "cd ${REPO} failed"
# --legacy is required on pnpm 11: the default (new) deploy implementation
# fails with a shared lockfile, and it resolves workspace packages as
# absolute file:// URLs so the repo's allowBuilds key (relative
# `file:packages/...`) no longer matches and strictDepBuilds turns the
# dsh-subprocess-local postinstall into a hard error. The legacy
# implementation hardlinks from the home store (no network) and keeps the
# relative spec, so allowBuilds matches. Verified 2026-10-17 on pnpm 11.28.5.
if ! pnpm --filter @deepseek-ai/dsh deploy --legacy --prod "${STAGE}"; then
  clean_stage "${STAGE}"
  log "deploy with --prod failed; retrying with the full (prod+dev) closure"
  pnpm --filter @deepseek-ai/dsh deploy --legacy "${STAGE}" || die "pnpm deploy failed in both modes"
fi
[ -f "${STAGE}/lib/bin.js" ] || die "deployed tree has no lib/bin.js (unexpected layout)"

log "fixups"
WEB_DIST="${STAGE}/node_modules/@deepseek-ai/dsh-web-frontend/dist"
if [ ! -d "${WEB_DIST}" ]; then
  echo "  NOTE: deployed tree lacks dsh-web-frontend/dist; copying apps/web/dist from the repo"
  mkdir -p "$(dirname "${WEB_DIST}")"
  cp -R "${REPO}/apps/web/dist" "${WEB_DIST}"
fi
if ! find "${STAGE}/node_modules" -name 'system.node' -path '*freebsd*' 2>/dev/null | grep -q .; then
  echo "  NOTE: no freebsd system.node in the deployed tree; copying the addon from the repo"
  DEST="${STAGE}/node_modules/@deepseek-ai/node-addon-system-freebsd-x64"
  mkdir -p "${DEST}"
  cp -R "${REPO}/native/system/packages/freebsd-x64/." "${DEST}/"
fi
cp "${REPO}/LICENSE" "${STAGE}/"
[ -f "${REPO}/THIRD_PARTY_NOTICES.md" ] && cp "${REPO}/THIRD_PARTY_NOTICES.md" "${STAGE}/"
mkdir -p "${STAGE}/freebsd"
cp "${REPO}/freebsd/dsh-jail-run.c" "${STAGE}/freebsd/"
find "${STAGE}" -name '*.tsbuildinfo' -delete 2>/dev/null
find "${STAGE}" -name '.pnpm-debug*' -delete 2>/dev/null

log "fixups: reconcile missing @deepseek-ai workspace packages"
# pnpm deploy installs `dependencies` but NOT peerDependencies of workspace
# packages: dsh-app-boot (and others) declare @deepseek-ai/cordis-plugin-group
# as a peer, so the deployed tree cannot boot without it. Resolve every
# workspace package name from the CLEAN source directories (never from
# node_modules — it holds dangling symlinks from upstream deletions and
# symlink cycles that break cp -RL) and copy the missing ones in.
cat > "${WORK}/reconcile.mjs" <<'RECONCILE_EOF'
import { existsSync, statSync, readdirSync, readFileSync, mkdirSync, cpSync } from 'node:fs'
import { join } from 'node:path'

const REPO = process.argv[2]
const STAGE = process.argv[3]
const DEP = join(STAGE, 'node_modules')

const map = new Map()
function scan(dir) {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return
  try {
    const p = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    if (p.name) map.set(p.name, dir)
  } catch { /* not a package dir */ }
}
function scanTwo(base) {
  if (!existsSync(base)) return
  for (const a of readdirSync(base)) {
    const p1 = join(base, a)
    if (!statSync(p1).isDirectory()) continue
    scan(p1)
    for (const b of readdirSync(p1)) {
      const p2 = join(p1, b)
      if (statSync(p2).isDirectory()) scan(p2)
    }
  }
}
scanTwo(join(REPO, 'packages'))
scanTwo(join(REPO, 'vendor'))
scanTwo(join(REPO, 'apps'))
scan(join(REPO, 'native', 'system'))
scanTwo(join(REPO, 'native', 'system', 'packages'))
scan(join(REPO, 'benchmarks'))
scan(join(REPO, 'website'))
scan(join(REPO, 'python', 'sdk-runtime'))

function destFor(name) {
  return name.startsWith('@') ? join(DEP, ...name.split('/')) : join(DEP, name)
}
const missing = []
for (const [name, dir] of map) {
  if (!existsSync(destFor(name))) missing.push([name, dir])
}
console.log(`  workspace packages: ${map.size}, missing in deploy: ${missing.length}`)
for (const [name, dir] of missing) {
  console.log(`  + ${name}  <-  ${dir.replace(REPO + '/', '')}`)
  mkdirSync(destFor(name), { recursive: true })
  cpSync(dir, destFor(name), {
    recursive: true,
    filter: (src) => {
      const rel = src.slice(dir.length)
      return !rel.startsWith('/node_modules') && !rel.startsWith('/.git')
    },
  })
}
RECONCILE_EOF
node "${WORK}/reconcile.mjs" "${REPO}" "${STAGE}" || die "workspace reconcile failed"

log "fixups: dereference source-pointing symlinks (make the bundle portable)"
# pnpm deploy --legacy leaves workspace packages as symlinks back into the
# build machine's source checkout (../../../../github/deepseek-harness/...).
# They resolve here but dangle on any other host, so the distfile would be
# non-portable. Replace every such symlink with a real copy of its target.
cd "${STAGE}" || die "cd ${STAGE} failed"
find node_modules -type l 2>/dev/null | while read -r l; do
  tgt=$(readlink "$l" 2>/dev/null || true)
  case "$tgt" in
    *github/deepseek-harness*)
      real=$(readlink -f "$l" 2>/dev/null || true)
      if [ -n "$real" ] && [ -e "$real" ]; then
        rm -f "$l"
        cp -R "$real" "$l"
      fi
      ;;
  esac
done
echo "  source symlinks remaining: $(find node_modules -type l 2>/dev/null | xargs -I{} readlink {} 2>/dev/null | grep -c github/deepseek-harness)"

log "size: $(du -sh "${STAGE}" | cut -f1)"

# --- smoke ------------------------------------------------------------------
FREE_MB=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null | awk '{printf "%d", $1*4096/1048576}')
echo "  free RAM: ${FREE_MB:-?} MB (guard: ${MIN_FREE_MB} MB)"
SMOKED=0
if [ -n "${FREE_MB}" ] && [ "${FREE_MB}" -lt "${MIN_FREE_MB}" ]; then
  echo "  SKIPPED: not enough free RAM for a safe smoke boot on this box."
  echo "           Re-run later, or lower DSH_MIN_FREE_MB. The tarball is still produced."
else
  log "smoke: boot the deployed tree on 127.0.0.1:${SMOKE_PORT}"
  SMOKE_HOME="${WORK}/smoke-home"
  mkdir -p "${SMOKE_HOME}"
  cd "${STAGE}" || die "cd ${STAGE} failed"
  # danger-full-access for the smoke only: no setuid jail helper is installed
  # in a scratch HOME, and this run validates the bundle, not the sandbox.
  env -i HOME="${SMOKE_HOME}" PATH="/usr/local/bin:/usr/bin:/bin" \
      DSH_HOME="${SMOKE_HOME}/.dsh" \
      DSH_PERMISSION_MODE=danger-full-access \
      "${NODE_BIN}" --expose-internals lib/bin.js \
      web --host 127.0.0.1 --port "${SMOKE_PORT}" --no-open \
      > "${WORK}/smoke.log" 2>&1 &
  SMOKE_PID=$!
  cleanup() { kill "${SMOKE_PID}" 2>/dev/null; wait "${SMOKE_PID}" 2>/dev/null; }
  trap cleanup EXIT INT TERM

  TOKEN=""
  i=0
  while [ "${i}" -lt 90 ]; do
    if ! kill -0 "${SMOKE_PID}" 2>/dev/null; then
      echo "FATAL: the deployed harness exited during boot; see ${WORK}/smoke.log" >&2
      tail -30 "${WORK}/smoke.log" >&2
      exit 1
    fi
    TOKEN=$(grep -oE 'token=[A-Za-z0-9_-]+' "${WORK}/smoke.log" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "${TOKEN}" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ -z "${TOKEN}" ]; then
    echo "FATAL: no token line within 90s; see ${WORK}/smoke.log" >&2
    tail -40 "${WORK}/smoke.log" >&2
    exit 1
  fi
  echo "  token: ${TOKEN}"

  # /?token= answers with a 303 that sets an HttpOnly auth cookie
  # (dsh-auth-...) and redirects into the SPA; the cookie jar is what makes
  # the followed request authorized. Browsers do this natively.
  JAR="${WORK}/smoke-jar"
  rm -f "${JAR}"
  CODE=$(curl -sL -c "${JAR}" -b "${JAR}" -o /dev/null -w '%{http_code}' \
         "http://127.0.0.1:${SMOKE_PORT}/?token=${TOKEN}" || echo 000)
  echo "  GET /?token=... (cookie jar, followed) -> ${CODE}"
  [ "${CODE}" = "200" ] || { echo "FATAL: expected 200, got ${CODE}" >&2; tail -40 "${WORK}/smoke.log" >&2; exit 1; }
  CODE2=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SMOKE_PORT}/" || echo 000)
  echo "  GET / (no token) -> ${CODE2} (401/403 expected: the trust fence is armed)"

  cleanup
  trap - EXIT INT TERM
  SMOKED=1
  log "smoke PASS (log: ${WORK}/smoke.log)"
fi

# --- tar --------------------------------------------------------------------
log "tar: ${DISTNAME}.tar.gz"
# Normalize ownership to root:wheel so extraction + staging keep files
# root-owned (bsdtar supports --uid/--gid; fall back to a plain tar).
if ! tar --uid 0 --gid 0 --uname root --gname wheel -czf "${WORK}/${DISTNAME}.tar.gz" \
       -C "${WORK}" "${DISTNAME}"; then
  echo "  NOTE: tar rejected the ownership flags; creating a plain tarball"
  tar -czf "${WORK}/${DISTNAME}.tar.gz" -C "${WORK}" "${DISTNAME}" || die "tar failed"
fi

SHA=$(sha256 -q "${WORK}/${DISTNAME}.tar.gz")
SIZE=$(wc -c < "${WORK}/${DISTNAME}.tar.gz" | tr -d ' ')

{
  echo "SHA256 (${DISTNAME}.tar.gz) = ${SHA}"
  echo "SIZE (${DISTNAME}.tar.gz) = ${SIZE}"
} > "${WORK}/distinfo.fragment"

{

  echo "bin/dsh"
  echo "@(root,wheel,4755) libexec/dsh-jail-run"
  cd "${STAGE}" && find . -mindepth 1 \( -type f -o -type l \) -print \
    | sed 's|^\./|libexec/deepseek-harness/|' | LC_ALL=C sort
} > "${WORK}/pkg-plist.fragment"

echo ""
echo "DONE."
echo "  distfile: ${WORK}/${DISTNAME}.tar.gz  (${SIZE} bytes)"
echo "  sha256:   ${SHA}"
if [ "${SMOKED}" = "1" ]; then
  echo "  smoke:    PASS"
else
  echo "  smoke:    SKIPPED (free-RAM guard) — re-run when the box is idle"
fi
echo "  fragments: ${WORK}/distinfo.fragment  ${WORK}/pkg-plist.fragment"
