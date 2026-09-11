---
description: "Prebuilt system.node for FreeBSD x64 POSIX locks."
kind: "package-library"
---
# @deepseek-ai/node-addon-system-freebsd-x64

English | [中文](README.zh.md)

This platform package supplies `bin/system.node`, a stable Node-API v8 addon used by `@deepseek-ai/node-addon-system/flock`. It contains no Landlock executable, JavaScript loader, or installation build script. `pnpm run build:native-system` builds it on FreeBSD x64 from the shared `flock.c` source, and the FreeBSD port owns its installed-artifact validation.
