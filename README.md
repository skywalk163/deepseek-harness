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
`pnpm-workspace.yaml`, so the standard flow works after cloning:

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh:freebsd web
```

The Web UI listens on `http://127.0.0.1:3080`. To open it from another machine,
forward the port: `ssh -L 3080:127.0.0.1:3080 <user>@<freebsd-host>`.

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

#### Verified on FreeBSD

`node-pty` compiles natively, `sharp` renders through WASM, `pnpm run build`
completes (`tsc -b` + `tsdown` + `vite`), and `dsh web` serves the UI over HTTP.

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
