#!/bin/zsh
# test:tauri 全管线入口：内核文件锁覆盖「前端构建 → Tauri 构建 → WDIO」。
# cargo target、CuePad.app bundle、测试数据目录均为共享写路径，
# 并行调用必须整体排队串行执行（锁随进程退出释放）。
set -eu

root=${0:A:h:h}
cd "$root"

zmodload zsh/system
touch /tmp/cuepad-wdio.lock
zsystem flock -f lock_fd /tmp/cuepad-wdio.lock

# 独立 identifier 的数据库与 WebKit 状态每轮清空，避免跨轮 fixture 污染；绝不触碰日常 CuePad 数据
rm -rf "$HOME/Library/Application Support/com.sugeh.cuepad.wdio"
rm -rf "$HOME/Library/WebKit/com.sugeh.cuepad.wdio"

# 前端产物与常驻 dev / 普通 bun run build 零共享写路径
export SVELTEKIT_OUT_DIR=.svelte-kit-wdio
export SVELTEKIT_BUILD_DIR=build-wdio

bun tauri build --debug --bundles app --config e2e-tauri/tauri.wdio.conf.json
# 不能 exec：zsystem flock 的 fd 带 close-on-exec，exec 会立即释放锁；
# 持锁的 zsh 父进程必须活到 WDIO 结束
node node_modules/@wdio/cli/bin/wdio.js run wdio.tauri.conf.ts
