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

RUTABAGA_REF="${RUTABAGA_REF:-main}"     # magma-gpu/rutabaga_gfx branch/tag
OUTDIR="${OUTDIR:-$(pwd)/rutabaga-install}"

echo "==> Fetching rutabaga_gfx (magma-gpu @ $RUTABAGA_REF)"
WORK="$(mktemp -d)"
git clone --depth 1 https://github.com/magma-gpu/rutabaga_gfx "$WORK/rutabaga_gfx"
cd "$WORK/rutabaga_gfx"
if [ "$RUTABAGA_REF" != "main" ]; then
    git fetch --depth 1 origin "$RUTABAGA_REF" && git checkout FETCH_HEAD
fi

# meson-native project (vendored rust crates via subprojects wraps; needs
# meson >= 1.3 + a rust toolchain on PATH, no cargo manifest resolution).
command -v meson >/dev/null || pip3 install meson
command -v rustc >/dev/null || { echo "rustc required on PATH"; exit 1; }

echo "==> meson setup (ffi enabled, no gpu backends yet)"
meson setup build     --buildtype release     --prefix "$OUTDIR"     -Dffi=true     -Dkumquat=false     -Dbuild-tests=false     -Dfeatures=[]

echo "==> Compiling"
meson compile -C build

echo "==> Installing (static lib + rutabaga_gfx_ffi.pc + headers)"
meson install -C build

echo "==> Artifacts"
find "$OUTDIR" -name '*.a' -o -name '*.pc' -o -name 'rutabaga*.h' | head -10
echo "==> Done: $OUTDIR (PKG_CONFIG_PATH=$OUTDIR/lib/pkgconfig)"
