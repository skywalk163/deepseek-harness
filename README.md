# DeepSeek Harness

English | [中文](README.zh.md)

DeepSeek Harness (`dsh`) is an open-source agent harness developed by [DeepSeek AI](https://deepseek.com).

It uses an architecture where **everything is a plugin**, and is powered by [Cordis](https://github.com/cordiverse/cordis), whose design is described in [_A Programming Paradigm for Spatiotemporal Composability_](https://github.com/cordiverse/paper).

## Developer preview

DeepSeek Harness is currently in _developer preview_ and is iterating rapidly. **THERE WILL BE COMPATIBILITY-BREAKING CHANGES.**

## Run

### Run from `npm`

Install `Node.js`, then run:

```sh
npx @deepseek-ai/dsh web
```

The command starts the Web UI, served at `http://127.0.0.1:3080` by default. See [Web UI guide](docs/user/guide/index.md).

### Run from source

To run from a repository checkout:

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```


### Run from source on FreeBSD

DeepSeek Harness runs on FreeBSD (verified on FreeBSD 14.3-RELEASE amd64 with
Node 24). Every FreeBSD-specific adjustment is already committed to
`pnpm-workspace.yaml`, so the standard flow works right after cloning:

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh:freebsd web
```

The Web UI listens on `http://127.0.0.1:3080` and **only answers to loopback
addresses** (see "Accessing the Web UI" below -- this is a hard security fence,
not a config toggle). To open it from another machine, use an SSH tunnel:
`ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>`, then browse
`http://localhost:3080`.

#### Prerequisites

```sh
pkg install node24 npm-node24 gmake python3 pkgconf
```

This repo pins `packageManager: pnpm@11.7.0`; the `pnpm` in FreeBSD ports may be
older. Install the pinned version, either globally as root or under your home:

```sh
npm install -g pnpm@11.7.0
# or, without root:
npm install pnpm@11.7.0 --prefix "$HOME/.pnpm-home"
export PATH="$HOME/.pnpm-home/node_modules/.bin:$PATH"
```

`corepack enable` is the usual alternative, but as a non-root user it fails with
`EACCES` because it writes shims into `/usr/local/bin`.

`node-pty` compiles a native addon during `pnpm install`, and `node-gyp` requires
GNU make invoked as `make` -- FreeBSD's `/usr/bin/make` is BSD make. Put a shim
early on `PATH`:

```sh
mkdir -p "$HOME/bin" && ln -sf /usr/local/bin/gmake "$HOME/bin/make"
export PATH="$HOME/bin:$PATH"
```

#### Why FreeBSD uses `pnpm dsh:freebsd`

`dsh:freebsd` is the normal `dsh` entry plus `--expose-internals`, and you must
also set `DSH_PERMISSION_MODE`:

- **`--expose-internals` is mandatory on FreeBSD.** The loader reaches Node's
  internal ESM loader either through that flag or through the
  `node-addon-require-builtin` native addon. That addon ships prebuilds for
  darwin/linux/win32 only -- there is no `node-addon-require-builtin-freebsd-x64`
  and no source-build fallback -- so on FreeBSD the flag is the only route.
  Without it the HMR service, which every long-lived surface such as `web` mounts
  unconditionally, aborts startup with
  `--expose-internals is required for HMR service`. The flag cannot be passed via
  `NODE_OPTIONS`; Node rejects it there.
- **The sandbox has no FreeBSD backend.** Confinement supports Linux
  (`bwrap`/`landlock`), macOS (`seatbelt`) and Windows ACL only, so on FreeBSD it
  fails closed and startup stops. Launch with:

  ```sh
  DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
  ```

  This runs the agent **unconfined**. Only do it on a machine you are willing to
  let the agent modify.

#### What is pre-configured for FreeBSD

All of it lives in `pnpm-workspace.yaml` -- pnpm v11 no longer reads the `pnpm`
field of `package.json`, and it reads only auth/registry keys from `.npmrc`:

- **`supportedArchitectures`** (`os: freebsd`, `cpu: x64` **and** `wasm32`).
  `sharp` publishes no native FreeBSD binary (`@img/sharp-freebsd-x64` does not
  exist), so its WASM path -- `@img/sharp-freebsd-wasm32` delegating to
  `@img/sharp-wasm32` -- is the only working image backend. That package declares
  `cpu: wasm32`, so pnpm's platform filter skips it on an x64 host unless
  `wasm32` is listed. Image processing therefore runs on WASM and is slower than
  a native build. Omitting this yields
  `Could not load the "sharp" module using the freebsd-x64 runtime` at startup.
- **`shamefullyHoist: true`**. The runtime loader resolves plugins through
  dynamic `import('@deepseek-ai/dsh-client-ui-*')`. Under pnpm's isolated layout
  those workspace packages never appear in the top-level `node_modules` and the
  import fails with `ERR_MODULE_NOT_FOUND`.
- **`packageExtensions` for `sharp`** -- redundant with `supportedArchitectures`,
  kept as an explicit declaration of the two WASM runtime packages.

`.npmrc` also points `registry` and `disturl` at the npmmirror mirror, which
makes FreeBSD platform tarballs and the `node-pty` Node-headers download
reliable from mainland China. Remove those two lines to use the default registry.

#### Accessing the Web UI (read this before exposing it anywhere)

> **You cannot reach the UI through nginx / Caddy / Apache or any reverse proxy,
> nor directly over a LAN IP or the public internet.** It only works through a
> loopback address (`localhost` / `127.0.0.1`).

The harness guards every host-side filesystem RPC -- including the "choose
workspace directory" picker (`host.listDirectory`) -- behind a **loopback-only
trust fence** (`packages/client/connection/src/rpc-host.ts`,
`api-request-trust.ts`). A request whose `Host` header is not a recognized
loopback name is rejected with `HTTP 403` before it reaches the handler. The
check accepts only `localhost`, `[::1]` and `127.x.x.x`.

What this means in practice:

- **Reverse proxy / LAN IP / public domain -> `403`.** Even if nginx forwards the
  request perfectly, the browser sends `Host: <lan-ip>:3080` (or your domain).
  The fence rejects it, and the very first file operation -- picking the
  workspace directory -- fails with
  `transport failure for /api/host.listDirectory: HTTP 403`. A stock reverse
  proxy preserves the client `Host`, so it cannot help; rewriting `Host`/`Origin`
  to `localhost:3080` is fragile and **not** recommended for beginners.
- **Plain `http://<lan-ip>:3080` directly -> also blocked**, for the same reason,
  and additionally the browser disables `crypto.randomUUID()` in a non-secure
  (non-localhost, non-HTTPS) context. (A polyfill is shipped to soften that, but
  the 403 fence is the real blocker for file operations.)

Supported ways to reach the UI:

1. **SSH tunnel (recommended).** On your workstation:
   ```sh
   ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>
   ```
   Then open `http://localhost:3080`. This gives a loopback `Host` (no 403)
   **and** a secure context (native `crypto.randomUUID` works) -- both pitfalls
   disappear at once.
2. **On the FreeBSD box itself**, just browse `http://127.0.0.1:3080` -- everything
   works natively.

If you truly need off-box access, present `localhost` to the browser (tunnel or
VPN), not a reverse proxy that keeps the client `Host`.

#### Running as a service (restart script + rc.d)

Two helper scripts live in the `workbuddy` home on the test host (adapt the
paths for your own user):

- `/home/workbuddy/dsh-web-run.sh` -- launcher: sets `DSH_PERMISSION_MODE`,
  `cd`s into the repo, and `exec`s `pnpm dsh:freebsd web`.
- `/home/workbuddy/dsh-web-restart.sh` -- one-shot control:
  `stop | start | restart | status` (default `restart`).

```sh
sh /home/workbuddy/dsh-web-restart.sh restart   # also: stop / start / status
```

For boot-time autostart, install the rc.d service (needs root):

```sh
su - root
cp /home/workbuddy/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
service dsh_web start        # verify
service dsh_web status
```

Notes:

- `pnpm` is persisted at `/home/workbuddy/.local/bin/pnpm` (v11.7.0, matching the
  repo's `packageManager`). Do **not** rely on a `/tmp/p117`-style path -- `/tmp`
  is cleared on reboot and the service would fail to start.
- The rc.d `pidfile` and log live under the home directory
  (`/home/workbuddy/dsh_web.pid`, `/home/workbuddy/dsh_web.log`) so they survive
  reboots and `/tmp` cleanup.
- The rc.d service runs as the `workbuddy` user; change `dsh_web_user` if you
  installed elsewhere.

#### Troubleshooting / known FreeBSD pitfalls

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Could not load the "sharp" module using the freebsd-x64 runtime` | `sharp` has no native FreeBSD binary; WASM path not installed | Keep `supportedArchitectures` (`os: freebsd`, `cpu` includes `wasm32`) and the `sharp` `packageExtensions` in `pnpm-workspace.yaml`. Do not remove them. |
| `ERR_MODULE_NOT_FOUND` for `@deepseek-ai/dsh-client-ui-*` | workspace plugins not hoisted | Keep `shamefullyHoist: true` in `pnpm-workspace.yaml`. |
| `--expose-internals is required for HMR service` | native addon path unavailable on FreeBSD | Use the `dsh:freebsd` script (adds `--expose-internals`). The flag cannot go in `NODE_OPTIONS`. |
| startup aborts / sandbox fail-closed | no FreeBSD sandbox backend | Launch with `DSH_PERMISSION_MODE=danger-full-access` (runs the agent unconfined). |
| `crypto.randomUUID is not a function` when picking a directory | non-secure context (plain http, non-localhost) | Browse via `http://localhost:3080` (SSH tunnel). A polyfill is included, but prefer localhost. |
| `transport failure for /api/host.listDirectory: HTTP 403` | loopback trust fence rejects non-loopback `Host` | Reach the UI via SSH tunnel / `localhost` (see "Accessing the Web UI"). Do **not** use a reverse proxy or LAN IP. |
| `node-pty` build fails / ETIMEDOUT fetching Node headers | `node-gyp` cannot reach headers | Keep `disturl=https://registry.npmmirror.com/-/binary/node` in `.npmrc` (or your nearest mirror); ensure the `gmake` shim is on `PATH`. |
| wrong `pnpm` / odd dependency resolution | version mismatch | Use exactly `pnpm@11.7.0` (repo `packageManager`). |
| `gen-third-party-notices` hook fails on commit/push | upstream hook needs `@anthropic-ai/claude-agent-sdk-linux-x64` (Linux-only build) | FreeBSD platform incompatibility, unrelated to your change. Bypass with `git commit --no-verify` or `git -c core.hooksPath=/tmp/nohooks push`. Content is safe when you have not added dependencies. |

#### Verified on FreeBSD

`node-pty` compiles natively, `sharp` renders through WASM, `pnpm run build`
completes (`tsc -b` + `tsdown` + `vite`), and `dsh web` serves the UI over HTTP
on loopback.


## Community and support

- Feel free to submit feedback or bug reports through [GitHub Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions).
- Add the [`dsh-plugin`](https://github.com/topics/dsh-plugin) topic to your plugin repository for discoverability.
- Join <a href="https://discord.gg/Ycq5dCaS4">DeepSeek Harness Discord community</a>.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Development

Start with the [development guide](docs/development.md) and [architecture documentation](docs/architecture.md).

For agents, follow [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE)

Third-party dependencies and their licenses are disclosed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
