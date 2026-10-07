#!/bin/bash
# Build the 3D paravirtualization chain into an existing UTM sysroot (opt-in,
# RUTABAGA_TRACK=1 in the dependency build):
#
#   gfxstream host (iOS, on MoltenVK)  ->  gfxstream_backend.pc
#        -> rutabaga_gfx (meson, -Dfeatures=gfxstream)  ->  rutabaga_gfx_ffi.pc
#        -> QEMU virtio-gpu-rutabaga (already in utmapp/QEMU, compiled when
#           meson finds rutabaga_gfx_ffi)
#
# Called from scripts/build_dependencies.sh AFTER build_qemu_dependencies and
# BEFORE the QEMU build itself; exports PKG_CONFIG_PATH additions. Every step
# is best-effort: a failure prints GATE data and returns nonzero, and the
# caller decides whether the track is fatal (it is only fatal when the 3D
# engine artifact is explicitly requested).
#
# Env:
#   SPGB_CHAIN_PREFIX   install prefix (default: $PREFIX/spgb-chain)
#   SPGB_GFXSTREAM_REF  google/gfxstream ref (default: main)
#   SPGB_SKIP_GFXSTREAM true to skip the host renderer (rutabaga then builds
#                       without backends — device plumbing only)
set -euo pipefail

CHAIN_PREFIX="${SPGB_CHAIN_PREFIX:-$PREFIX/spgb-chain}"
GFXSTREAM_REF="${SPGB_GFXSTREAM_REF:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
PC_DIR="$CHAIN_PREFIX/lib/pkgconfig"
mkdir -p "$PC_DIR" "$CHAIN_PREFIX/include"

echo "==> [3D chain] target prefix: $CHAIN_PREFIX"

# --------------------------------------------------------------- gfxstream
if [ "${SPGB_SKIP_GFXSTREAM:-0}" != "true" ]; then
    echo "==> [3D chain] fetching gfxstream ($GFXSTREAM_REF)"
    git clone --depth 1 "https://github.com/google/gfxstream" "$WORK/gfxstream"
    GFXSTREAM_PATCH="$SCRIPT_DIR/gfxstream-host/patch-ios.sh"
    if [ -f "$GFXSTREAM_PATCH" ]; then
        bash "$GFXSTREAM_PATCH" "$WORK/gfxstream" ios
    else
        echo "GATE DATA: patch-ios.sh not found at $GFXSTREAM_PATCH"; exit 2
    fi

    echo "==> [3D chain] configuring gfxstream host for iOS"
    # Include order proven green in the vulkan-track iOS leg: vendored shim
    # Vulkan headers -> gfxstream's vendored vulkan headers (must not be
    # shadowed) -> vk_video. No MoltenVK dependency for compilation.
    SHIM="$(cd "$(dirname "$0")/gfxstream-host/shim-headers" && pwd)"
    cmake -S "$WORK/gfxstream" -B "$WORK/gfxstream-build" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_CXX_FLAGS="-I$SHIM/vulkan -I$WORK/gfxstream/third_party/vulkan/include -I$SHIM/vk_video" \
        -DCMAKE_INSTALL_PREFIX="$CHAIN_PREFIX" || {
        echo "GATE DATA: gfxstream cmake configure failed for iOS"; exit 2;
    }
    set -o pipefail
    (cmake --build "$WORK/gfxstream-build" --parallel 4 || \
     cmake --build "$WORK/gfxstream-build") 2>&1 | tee "$WORK/gfxstream-build.log" || {
        echo "GATE DATA: gfxstream host build failed for iOS (see gfxstream-build.log artifact)"; exit 3;
    }
    cmake --install "$WORK/gfxstream-build" || true
    cp "$WORK/gfxstream-build.log" "$CHAIN_PREFIX/" 2>/dev/null || true

    # gfxstream's cmake does not ship a pc file; write the one rutabaga needs.
    GFXSTREAM_LIBDIR="$CHAIN_PREFIX/lib"
    cat > "$PC_DIR/gfxstream_backend.pc" <<EOF
prefix=$CHAIN_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gfxstream_backend
Description: gfxstream host renderer (SteamPhone 3D chain)
Version: 0.1.2
Libs: -L\${libdir} -lgfxstream_backend
Cflags: -I\${includedir} -I$SHIM/vulkan -I$SHIM/vk_video
EOF
    # Stage the backend headers rutabaga's ffi build includes.
    cp -R "$WORK/gfxstream/include/." "$CHAIN_PREFIX/include/" 2>/dev/null || true
    echo "==> [3D chain] gfxstream installed; pc at $PC_DIR/gfxstream_backend.pc"
fi

# ---------------------------------------------------------------- rutabaga
echo "==> [3D chain] building rutabaga_gfx (magma-gpu, meson-native)"
git clone --depth 1 "https://github.com/magma-gpu/rutabaga_gfx" "$WORK/rutabaga_gfx"
RUTABAGA_FEATURES="[]"
if [ "${SPGB_SKIP_GFXSTREAM:-0}" != "true" ] && [ -f "$PC_DIR/gfxstream_backend.pc" ]; then
    RUTABAGA_FEATURES="['gfxstream']"
fi
export PKG_CONFIG_PATH="$PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cd "$WORK/rutabaga_gfx"

# build_dependencies.sh exports CFLAGS/CPPFLAGS/LDFLAGS/RUSTFLAGS for its own
# cross builds; they leak into meson's sanity checks here and corrupt the
# command lines. The cross file below carries everything needed.
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS RUSTFLAGS CARGO_BUILD_RUSTFLAGS 2>/dev/null || true

# Cross file when targeting iOS from macOS: meson sanity-checks the C compiler
# by RUNNING its output, which cannot work for an iOS target — the cross file
# tells meson the host machine differs so it skips the sanity run.
CROSS_ARGS=()
if [ "${RUTABAGA_TARGET:-aarch64-apple-ios}" = "aarch64-apple-ios" ] && [ "$(uname)" = "Darwin" ]; then
    IOS_SDK="$(xcrun --show-sdk-path --sdk iphoneos)"
    cat > "$WORK/ios-cross.txt" <<EOF
[binaries]
c = ['clang', '-target', 'arm64-apple-ios15.0', '-isysroot', '$IOS_SDK']
cpp = ['clang++', '-target', 'arm64-apple-ios15.0', '-isysroot', '$IOS_SDK']
rust = ['rustc', '--target', 'aarch64-apple-ios', '-C', 'link-arg=-isysroot', '-C', 'link-arg=$IOS_SDK']
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
    CROSS_ARGS=(--cross-file "$WORK/ios-cross.txt")
    echo "==> [3D chain] using iOS cross file (needs_exe_wrapper=true)"
fi

# Rust diagnostics + guaranteed iOS std, in the exact context meson runs in.
echo "==> [3D chain] rust context: which=$(command -v rustc) $(rustc --version 2>&1)"
echo "==> [3D chain] RUSTUP_HOME=${RUSTUP_HOME:-unset} CARGO_HOME=${CARGO_HOME:-unset} HOME=$HOME"
rustup target add aarch64-apple-ios 2>&1 || true
echo "==> [3D chain] std libs for aarch64-apple-ios:"
TLD="$(rustc --print target-libdir --target aarch64-apple-ios 2>&1)"
echo "    $TLD"; ls "$TLD" 2>/dev/null | grep -E "libstd|librstd" | head -3

# meson's rust cross sanity/linker probes are flaky (nondeterministic between
# runs on the same commit); setup+compile are retried from a clean build dir.
RUT_OK=0
for attempt in 1 2 3; do
    rm -rf build-rutabaga
    if meson setup build-rutabaga \
        --buildtype release \
        --prefix "$CHAIN_PREFIX" \
        "${CROSS_ARGS[@]}" \
        -Dffi=true -Dkumquat=false -Dbuild-tests=false \
        -Dfeatures="$RUTABAGA_FEATURES" \
       && meson compile -C build-rutabaga \
       && meson install -C build-rutabaga; then
        RUT_OK=1
        break
    fi
    echo "==> [3D chain] rutabaga attempt $attempt failed; retrying clean"
done
[ "$RUT_OK" = "1" ] || { echo "GATE DATA: rutabaga build failed after retries"; exit 5; }

echo "==> [3D chain] complete:"
find "$CHAIN_PREFIX" \( -name '*.a' -o -name '*.pc' \) | head -12
echo "==> [3D chain] remember: QEMU needs PKG_CONFIG_PATH=$PC_DIR"
