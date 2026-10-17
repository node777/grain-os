#!/usr/bin/env bash
# Install the Grain toolchain: Zig (pinned), QEMU, OpenSBI, GDB, Python.
#   Debian/Ubuntu: apt packages, Zig in /opt/zig (needs root or sudo).
#   macOS:         Homebrew packages, Zig in ~/opt/zig-<version>; no sudo.
# The Zig download is checked against the checksum ziglang.org publishes.
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.17.0}"

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) echo "setup: unsupported system $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    arm64 | aarch64) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "setup: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

if [ "$os" = macos ]; then
    if [ "$(id -u)" -eq 0 ]; then
        echo "setup: on macOS, run this as yourself, not with sudo" >&2
        exit 1
    fi
    if ! command -v brew >/dev/null; then
        echo "setup: Homebrew is needed first: https://brew.sh" >&2
        exit 1
    fi
    brew install qemu python@3.12
    PREFIX="${PREFIX:-$HOME/opt/zig-$ZIG_VERSION}"
elif command -v apt-get >/dev/null; then
    sudo_cmd=""
    [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
    $sudo_cmd apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y -qq \
        qemu-system-misc qemu-system-x86 qemu-system-arm opensbi gdb-multiarch python3 curl xz-utils
    PREFIX="${PREFIX:-/opt/zig}"
else
    PREFIX="${PREFIX:-/opt/zig}"
fi

if [ "$("$PREFIX/zig" version 2>/dev/null || true)" != "$ZIG_VERSION" ]; then
    read -r url shasum < <(curl -fsSL https://ziglang.org/download/index.json |
        python3 -c "import json,sys; r=json.load(sys.stdin)['$ZIG_VERSION']['$arch-$os']; print(r['tarball'], r['shasum'])")
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/zig.tar.xz" "$url"
    if command -v sha256sum >/dev/null; then
        got="$(sha256sum "$tmp/zig.tar.xz" | cut -d' ' -f1)"
    else
        got="$(shasum -a 256 "$tmp/zig.tar.xz" | cut -d' ' -f1)"
    fi
    if [ "$got" != "$shasum" ]; then
        echo "setup: the Zig download does not match its published checksum; not installing" >&2
        exit 1
    fi
    mkdir -p "$PREFIX"
    tar -xJf "$tmp/zig.tar.xz" -C "$PREFIX" --strip-components=1
    if [ "$os" = linux ]; then
        ln -sf "$PREFIX/zig" /usr/local/bin/zig
    fi
fi

if [ "$os" = macos ]; then
    case ":$PATH:" in
        *":$PREFIX:"*) ;;
        *) echo "setup: add Zig to your PATH:  echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
    esac
fi

"$PREFIX/zig" version
qemu-system-riscv64 --version | head -1
