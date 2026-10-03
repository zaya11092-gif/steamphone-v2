#!/bin/bash
# Build rutabaga_gfx's FFI crate (crosvm's paravirt-GPU backend framework).
#
# DISCOVERY (2026-10): utmapp/QEMU v10.0.12-utm already contains the full
# virtio-gpu-rutabaga device (hw/display/virtio-gpu-rutabaga.c + PCI
# variant), compiled only when meson finds the `rutabaga_gfx_ffi`
# pkg-config dependency. UTM's own iOS build never provides it (no Rust
# toolchain), so the device is dormant. This script wakes it up: build the
# ffi crate via cargo, stage its headers, and write a rutabaga_gfx_ffi.pc
# so QEMU's meson picks it up.
#
# Targets:
#   RUTABAGA_TARGET=aarch64-apple-ios  (default; device cross-compile)
#   RUTABAGA_TARGET=""                 (native build — used by the spike)
#
# Spike status: minimal-feature build first (--no-default-features). The
# gfxstream backend feature (which builds the C++ host renderer inside
# rutabaga's build) is the next gate — see gpu-rd/3d-plan.md WP3/WP4.
# Feature names to iterate on live in the fetched tree's Cargo.toml.
set -euo pipefail

RUTABAGA_REF="${RUTABAGA_REF:-main}"     # crosvm monorepo, rutabaga_gfx/ workspace
RUTABAGA_TARGET="${RUTABAGA_TARGET-aarch64-apple-ios}"
MIN_IOS="${MIN_IOS:-15.0}"
OUTDIR="${OUTDIR:-$(pwd)/rutabaga-build}"
PKGCONFIG_DIR="$OUTDIR/lib/pkgconfig"

command -v rustup >/dev/null || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
if [ -n "$RUTABAGA_TARGET" ]; then
    rustup target add "$RUTABAGA_TARGET"
fi

echo "==> Fetching crosvm (rutabaga_gfx @ $RUTABAGA_REF)"
WORK="$(mktemp -d)"
git clone --depth 1 --branch "$RUTABAGA_REF" https://chromium.googlesource.com/crosvm/crosvm "$WORK/crosvm" 2>/dev/null \
  || git clone --depth 1 https://chromium.googlesource.com/crosvm/crosvm "$WORK/crosvm"
cd "$WORK/crosvm/rutabaga_gfx"

echo "==> cbindgen CLI (build.rs of the ffi crate invokes it in some revisions)"
command -v cbindgen >/dev/null || cargo install --locked cbindgen || true

mkdir -p "$OUTDIR/lib" "$PKGCONFIG_DIR" "$OUTDIR/include"

# QEMU's meson wants pkg-config name 'rutabaga_gfx_ffi' -> the ffi sub-crate.
echo "==> Building rutabaga_gfx_ffi ($([ -n "$RUTABAGA_TARGET" ] && echo "$RUTABAGA_TARGET" || echo native), minimal features)"
if [ -n "$RUTABAGA_TARGET" ]; then
    env IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" \
        cargo build --release --target "$RUTABAGA_TARGET" -p rutabaga_gfx_ffi --no-default-features
    find "target/$RUTABAGA_TARGET/release" -name '*.a' -exec cp {} "$OUTDIR/lib/" \;
else
    cargo build --release -p rutabaga_gfx_ffi --no-default-features
    find target/release -maxdepth 1 -name '*.a' -exec cp {} "$OUTDIR/lib/" \;
fi

echo "==> Collecting headers (build.rs cbindgen output, tree-wide fallback)"
find . "$WORK/crosvm/target" -name 'rutabaga*.h' -exec cp {} "$OUTDIR/include/" \; 2>/dev/null || true
ls "$OUTDIR/include" || true

echo "==> Writing rutabaga_gfx_ffi.pc"
cat > "$PKGCONFIG_DIR/rutabaga_gfx_ffi.pc" <<EOF
prefix=$OUTDIR
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: rutabaga_gfx_ffi
Description: rutabaga_gfx FFI (paravirt GPU framework, QEMU meson dep name)
Version: 0.1
Libs: -L\${libdir} -lrutabaga_gfx_ffi
Cflags: -I\${includedir}
EOF

echo "==> Done: $OUTDIR (PKG_CONFIG_PATH=$PKGCONFIG_DIR)"
