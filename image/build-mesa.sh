#!/bin/bash
# Build Mesa with the gfxstream guest components for aarch64 (WP2 of
# gpu-rd/3d-plan.md). Runs INSIDE the arm64 image-build container (see
# chroot-build.sh) so the result targets the guest natively — no
# qemu-user overhead for the compile.
#
# KNOWN ITERATION POINTS (this script is the vehicle, expect CI round-trips):
#  - The exact meson option set for gfxstream guest components: upstream
#    Mesa wires them under src/gfxstream/guest; depending on the release the
#    toggles are -Dgfxstream-vulkan / -Dgfxstream-gles or they ride along
#    with -Dplatforms=... + virtio winsys. `meson setup --help` output is
#    dumped on failure to pin the names quickly.
#  - MESA_REF pin: first release line with gfxstream merged (24.3.x). Verify
#    the tag exists: https://gitlab.freedesktop.org/mesa/mesa/-/tags
set -euo pipefail

MESA_REF="${MESA_REF:-mesa-24.3.4}"
PREFIX="/usr/local/mesa-gfxstream"
JOBS="${JOBS:-$(nproc)}"

echo "==> Build dependencies"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config python3-mako python3-yaml \
    bison flex libexpat1-dev zlib1g-dev libzstd-dev libllvm17 llvm-17-dev \
    libwayland-dev wayland-protocols libdrm-dev \
    libx11-dev libxext-dev libxfixes-dev libxcb1-dev libxcb-dri3-dev \
    libxcb-present-dev libxshmfence-dev libxxf86vm-dev \
    git ca-certificates

WORK="$(mktemp -d)"
cd "$WORK"

echo "==> Fetching Mesa ($MESA_REF)"
if ! git clone --depth 1 --branch "$MESA_REF" https://gitlab.freedesktop.org/mesa/mesa.git mesa; then
    echo "    tag '$MESA_REF' not found — trying default branch (iteration mode)"
    git clone --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git mesa
fi
cd mesa

echo "==> Configuring"
# Target matrix:
#  - gfxstream guest (virtio-gpu paravirt driver: the 3D track's guest side)
#  - llvmpipe/lavapipe kept as software fallback (the shipped v1 behavior)
#  - no X11 drivers needed beyond what cage/wayland requires
set +e
meson setup build \
    --prefix "$PREFIX" \
    --buildtype release \
    -Dplatforms=wayland \
    -Dglx=disabled \
    -Degl=enabled \
    -Dgbm=enabled \
    -Dopengl=true \
    -Dgles1=disabled -Dgles2=enabled \
    -Dgallium-drivers=llvmpipe,gfxstream \
    -Dvulkan-drivers=swrast \
    -Dvideo-codecs= \
    -Dtools= \
    -Dzstd=enabled \
    2>&1 | tee /tmp/meson-config.log
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" -ne 0 ]; then
    echo "==> meson configure failed; gfxstream/virtio-related options in this tree:"
    grep -i -B1 -A3 'gfxstream\|virtio' meson_options.txt || echo "(none found — option names changed upstream; check meson_options.txt)"
    echo "==> all defined options:"
    grep -E "^\s*option\(" meson_options.txt | head -100 || true
    exit 1
fi

echo "==> Compiling (${JOBS} jobs — this is the slow step)"
ninja -C build -j "$JOBS"

echo "==> Installing to $PREFIX (staged; image assembly links it into the guest)"
ninja -C build install

echo "==> Staging environment for the guest"
mkdir -p /etc/profile.d
cat > /etc/profile.d/90-mesa-gfxstream.sh <<'EOF'
# gfxstream-backed Vulkan/GL when the virtio-gpu 3D context is present,
# transparent llvmpipe/lavapipe fallback otherwise.
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/usr/local/mesa-gfxstream/lib/aarch64-linux-gnu:/usr/local/mesa-gfxstream/lib"
export VK_ICD_FILENAMES="/usr/local/mesa-gfxstream/share/vulkan/icd.d/lvp_icd.aarch64.json"
EOF

echo "==> Mesa guest driver build complete"
