#!/bin/bash
# Build rutabaga_gfx (crosvm's paravirt-GPU backend framework).
#
# DISCOVERY (2026-10): utmapp/QEMU v10.0.12-utm already contains the full
# virtio-gpu-rutabaga device (hw/display/virtio-gpu-rutabaga.c + PCI
# variant), compiled only when meson finds the `rutabaga` dependency.
# UTM's own iOS build never provides it (no Rust toolchain), so the device
# is dormant. This script wakes it up: produce rutabaga via cargo and expose
# it through pkg-config so QEMU's meson picks it up.
#
# Targets:
#   RUTABAGA_TARGET=aarch64-apple-ios  (default; device cross-compile)
#   RUTABAGA_TARGET=""                 (native build — used by the spike)
#
# Spike status: minimal-feature build first. The gfxstream backend feature
# (which builds the C++ host renderer inside rutabaga's build) is the next
# gate — see gpu-rd/3d-plan.md WP3/WP4. Feature names to iterate on live in
# the fetched tree's Cargo.toml [features].
set -euo pipefail

RUTABAGA_REF="${RUTABAGA_REF:-main}"     # crosvm monorepo, rutabaga_gfx/ and cros_lib/
RUTABAGA_TARGET="${RUTABAGA_TARGET-aarch64-apple-ios}"
MIN_IOS="${MIN_IOS:-15.0}"
OUTDIR="${OUTDIR:-$(pwd)/rutabaga-build}"
PKGCONFIG_DIR="$OUTDIR/lib/pkgconfig"

command -v rustup >/dev/null || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
if [ -n "$RUTABAGA_TARGET" ]; then
    rustup target add "$RUTABAGA_TARGET"
fi

echo "==> Fetching rutabaga (crosvm @ $RUTABAGA_REF)"
WORK="$(mktemp -d)"
git clone --depth 1 --branch "$RUTABAGA_REF" https://chromium.googlesource.com/crosvm/platform2 "$WORK/platform2" 2>/dev/null \
  || git clone --depth 1 https://chromium.googlesource.com/crosvm/platform2 "$WORK/platform2"
cd "$WORK/platform2/rutabaga_gfx"

echo "==> cbindgen for the C headers QEMU compiles against"
command -v cbindgen >/dev/null || cargo install --locked cbindgen

mkdir -p "$OUTDIR/lib" "$PKGCONFIG_DIR" "$OUTDIR/include"

echo "==> Building rutabaga_core ($([ -n "$RUTABAGA_TARGET" ] && echo "$RUTABAGA_TARGET" || echo native), minimal features)"
if [ -n "$RUTABAGA_TARGET" ]; then
    env IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" \
        cargo build --release --target "$RUTABAGA_TARGET" --no-default-features
    find "target/$RUTABAGA_TARGET/release" -name '*.a' -exec cp {} "$OUTDIR/lib/" \;
else
    cargo build --release --no-default-features
    find target/release -maxdepth 1 -name '*.a' -exec cp {} "$OUTDIR/lib/" \;
fi

echo "==> Generating headers"
cbindgen --crate rutabaga_core -o "$OUTDIR/include/rutabaga.h" || true
[ -s "$OUTDIR/include/rutabaga.h" ] || {
    echo "    cbindgen produced nothing; falling back to cros_lib headers"
    cp -R "$WORK/platform2/cros_lib/include/." "$OUTDIR/include/" 2>/dev/null || true
}

echo "==> Writing rutabaga.pc"
cat > "$PKGCONFIG_DIR/rutabaga.pc" <<EOF
prefix=$OUTDIR
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: rutabaga
Description: rutabaga_gfx (paravirt GPU framework)
Version: 0.1
Libs: -L\${libdir} -lrutabaga_core
Cflags: -I\${includedir}
EOF

echo "==> Done: $OUTDIR (PKG_CONFIG_PATH=$PKGCONFIG_DIR)"
