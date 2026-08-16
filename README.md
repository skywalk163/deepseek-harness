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


> **Full step-by-step installation runbook:** See [FREEBSD.md](FREEBSD.md) for a complete, copy-paste install guide — prerequisites, the `@pnpm/exe.freebsd-x64` pitfall, gmake shim, bash dependency, loopback fence, service/rc.d, git remotes, and a troubleshooting table.


```sh
git clone https://gitcode.com/skywalk163/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh:freebsd web
```


#### Prerequisites

```sh
pkg install node24 npm-node24 gmake python3 pkgconf bash
```



```sh
npm install -g pnpm@11.7.0
# or, without root:
npm install pnpm@11.7.0 --prefix "$HOME/.pnpm-home"
export PATH="$HOME/.pnpm-home/node_modules/.bin:$PATH"
```



```sh
mkdir -p "$HOME/bin" && ln -sf /usr/local/bin/gmake "$HOME/bin/make"
export PATH="$HOME/bin:$PATH"
```

#### Why FreeBSD uses `pnpm dsh:freebsd`



  ```sh
  DSH_PERMISSION_MODE=danger-full-access pnpm dsh:freebsd web
  ```


#### What is pre-configured for FreeBSD




#### Accessing the Web UI (read this before exposing it anywhere)



What this means in practice:


Supported ways to reach the UI:

1. **SSH tunnel (recommended).** On your workstation:
   ```sh
   ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>
   ```
2. **On the FreeBSD box itself**, just open `http://127.0.0.1:3080` — everything works natively.


#### Running as a service (restart script + rc.d)


- `freebsd/dsh_web.rcd` -- rc.d service template.

Run the service directly (no root needed):

```sh
sh freebsd/dsh-web-restart.sh restart   # also: stop / start / status
```


```sh
su - root
cp freebsd/dsh_web.rcd /usr/local/etc/rc.d/dsh_web
chmod 555 /usr/local/etc/rc.d/dsh_web
sysrc dsh_web_enable=YES
sysrc dsh_web_chdir="$(pwd)"     # repo path, auto-filled; run this in the repo
sysrc dsh_web_user=workbuddy     # change if your account is not "workbuddy"
service dsh_web start            # verify
service dsh_web status
```

Notes:


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
| `PTY shell exited during startup` / `terminal-bash: ... does not exist` | `bash` not installed (FreeBSD ships `/bin/sh`, not bash); the `terminal-bash` backend requires bash (`PROMPT_COMMAND` + `--noprofile/--norc`) | `pkg install bash` (or `cd /usr/ports/shells/bash && make install clean`). The backend cannot use the default `/bin/sh`. |

#### Verified on FreeBSD



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
