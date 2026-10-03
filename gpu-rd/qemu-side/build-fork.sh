#!/bin/bash
# QEMU fork spike (WP4): prove the pinned utmapp/QEMU builds the dormant
# virtio-gpu-rutabaga device once the rutabaga dependency exists.
#
# Strategy: NATIVE macOS configure+build. This isolates the gate question —
# "does the rutabaga device path compile and get selected in this tree?" —
# from iOS cross-compilation, which scripts/build_dependencies.sh already
# handles for everything else. Once native passes, flipping the iOS build is
# a dependency-pipeline change (build rutabaga for ios-arm64, export
# PKG_CONFIG_PATH, same flags).
#
# Gate output: whether config-all-devices.mak selects virtio-gpu-rutabaga,
# and whether the module links. Run on macOS (GitHub Actions macos runner).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="${QEMU_FORK_WORK:-$(pwd)/qemu-fork-work}"
QEMU_SRC="https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz"
UTM_PATCH="$REPO_ROOT/patches/qemu-10.0.12-utm.patch"

mkdir -p "$WORK"
cd "$WORK"

echo "==> Fetching pinned QEMU"
if [ ! -d qemu-10.0.12-utm ]; then
    curl -fL --retry 3 -o qemu.tar.xz "$QEMU_SRC"
    tar -xf qemu.tar.xz
fi
cd qemu-10.0.12-utm

echo "==> Applying UTM's qemu patch (goes first; our layers ride on top)"
if [ ! -f .utm-patched ]; then
    patch -p1 < "$UTM_PATCH"
    touch .utm-patched
fi

echo "==> Building rutabaga (native, minimal features)"
export RUTABAGA_TARGET=""
export OUTDIR="$WORK/rutabaga-native"
bash "$SCRIPT_DIR/build-rutabaga.sh"
export PKG_CONFIG_PATH="$OUTDIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "==> Configuring QEMU (native, aarch64-softmmu only, minimal)"
mkdir -p build-spike && cd build-spike
../configure --target-list=aarch64-softmmu 2>&1 | tee ../configure-spike.log

echo "==> Gate check: is virtio-gpu-rutabaga selected?"
GATE=unknown
if grep -q "CONFIG_VIRTIO_GPU_RUTABAGA=y\|virtio-gpu-rutabaga" config-all-devices.mak 2>/dev/null \
   || grep -q "virtio-gpu-rutabaga" config-host.mak 2>/dev/null; then
    echo "GATE PASS: virtio-gpu-rutabaga selected by configure"
    GATE=pass
else
    echo "GATE DATA: not selected — dependency detection failed?"
    grep -i "rutabaga" ../configure-spike.log || echo "(no rutabaga mention in configure log)"
    GATE=fail
fi

echo "==> Building (aarch64-softmmu)"
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" 2>&1 | tail -15

echo "==> Resulting modules mentioning rutabaga/gfxstream:"
find . -name '*rutabaga*' -o -name '*gfxstream*' | head -10

echo "==> Spike complete (gate: $GATE)."
exit 0   # spike failures are gate data, not build failures — CI reads the log
