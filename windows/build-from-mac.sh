#!/bin/bash
# Build the Windows binaries on a Mac, for quick test loops in a Windows VM.
#   windows/build-from-mac.sh [cargo build args...]
#
# Uses its own rustup toolchain and the MSVC CRT/SDK libraries (fetched by xwin)
# under $BCU_WIN_TOOLS (default /tmp/bcu-win-tools), and links with rust-lld,
# so nothing else on the Mac changes. On Windows, just run `cargo build`.
set -euo pipefail
cd "$(dirname "$0")"

TOOLS="${BCU_WIN_TOOLS:-/tmp/bcu-win-tools}"
export RUSTUP_HOME="$TOOLS/rustup" CARGO_HOME="$TOOLS/cargo"
export PATH="$CARGO_HOME/bin:$PATH"
TARGET=x86_64-pc-windows-msvc

if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal -t "$TARGET"
fi
if [ ! -d "$TOOLS/xwin/crt" ]; then
  cargo install xwin --locked
  xwin --accept-license --cache-dir "$TOOLS/xwin-cache" --arch x86_64 splat --output "$TOOLS/xwin"
fi

LLD="$(ls "$RUSTUP_HOME"/toolchains/*/lib/rustlib/*/bin/rust-lld | head -1)"
L="$TOOLS/xwin"
export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="$LLD"
export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS="-Ctarget-feature=+crt-static -Clinker-flavor=lld-link -Clink-arg=/ignore:4099 \
-Lnative=$L/crt/lib/x86_64 -Lnative=$L/sdk/lib/um/x86_64 -Lnative=$L/sdk/lib/ucrt/x86_64"

cargo build --release --target "$TARGET" "$@"
echo "built: $(pwd)/target/$TARGET/release/"
