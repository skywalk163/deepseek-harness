---
description: "为 FreeBSD x64 POSIX 锁提供预编译 system.node。"
kind: "package-library"
---
# @deepseek-ai/node-addon-system-freebsd-x64

[English](README.md) | 中文

此平台包提供 `bin/system.node`，供 `@deepseek-ai/node-addon-system/flock` 使用的稳定 Node-API v8 addon。它不包含 Landlock 可执行文件、JavaScript 加载器或安装构建脚本。`pnpm run build:native-system` 在 FreeBSD x64 上从共用的 `flock.c` 源码构建它，并由 FreeBSD 移植负责验证安装后的产物。
