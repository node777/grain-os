#!/usr/bin/env bash
# Install the Grain toolchain on Debian/Ubuntu: Zig (pinned), QEMU, OpenSBI, GDB.
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.17.0}"
PREFIX="${PREFIX:-/opt/zig}"

if command -v apt-get >/dev/null; then
    sudo_cmd=""
    [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
    $sudo_cmd apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y -qq \
        qemu-system-misc qemu-system-x86 qemu-system-arm opensbi gdb-multiarch python3 curl xz-utils
fi

if [ "$(zig version 2>/dev/null || true)" != "$ZIG_VERSION" ]; then
    arch="$(uname -m)"
    url="$(curl -fsSL https://ziglang.org/download/index.json |
        python3 -c "import json,sys; print(json.load(sys.stdin)['$ZIG_VERSION']['$arch-linux']['tarball'])")"
    mkdir -p "$PREFIX"
    curl -fsSL "$url" | tar -xJ -C "$PREFIX" --strip-components=1
    ln -sf "$PREFIX/zig" /usr/local/bin/zig
fi

zig version
qemu-system-riscv64 --version | head -1
