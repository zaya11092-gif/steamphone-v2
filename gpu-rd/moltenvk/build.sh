#!/bin/bash
# Build MoltenVK (Vulkan-on-Metal) for iOS arm64 as a static xcframework,
# plus a Swift-importable Vulkan module (headers copied out of the build
# tree). Runs on a macOS host with Xcode (GitHub Actions macos runner).
#
# Usage: ./build.sh [ref]      (ref = git tag/branch/commit, default below)
# Output: gpu-rd/moltenvk/build/MoltenVK.xcframework
#         gpu-rd/moltenvk/module/{vulkan,module.modulemap}
set -euo pipefail

MOLTENVK_REF="${1:-${MOLTENVK_REF:-v1.4.2}}"   # override if the tag moved
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/build"
SRC="$OUT/src"

mkdir -p "$OUT"
command -v xcodebuild >/dev/null || { echo "Xcode required"; exit 1; }

echo "==> Fetching MoltenVK ($MOLTENVK_REF)"
rm -rf "$SRC"
if ! git clone --depth 1 --branch "$MOLTENVK_REF" https://github.com/KhronosGroup/MoltenVK "$SRC"; then
    echo "    tag '$MOLTENVK_REF' not found; falling back to default branch"
    git clone --depth 1 https://github.com/KhronosGroup/MoltenVK "$SRC"
fi

cd "$SRC"

echo "==> Fetching dependencies (flag set varies across MoltenVK revisions)"
./fetchDependencies --ios || ./fetchDependencies ||     { echo "fetchDependencies failed"; exit 1; }

echo "==> Building static iOS framework (device)"
# MoltenVK's Makefile: 'make ios' builds the Static iOS framework into
# Package/Release/MoltenVK/static/. Only the iOS-device slice is needed.
make ios MVK_CONFIG_LOG_LEVEL=1

echo "==> Locating built framework"
FRAMEWORK="$(find Package -name 'MoltenVK.xcframework' -type d | head -1)"
if [ -z "$FRAMEWORK" ]; then
    FRAMEWORK="$(find . -name 'MoltenVK.framework' -type d -path '*iOS*' | head -1)"
fi
[ -n "$FRAMEWORK" ] || { echo "no MoltenVK framework produced"; exit 1; }
rm -rf "$OUT/MoltenVK.xcframework"
cp -R "$FRAMEWORK" "$OUT/MoltenVK.xcframework"
echo "    -> $OUT/MoltenVK.xcframework"

echo "==> Staging Vulkan headers for Swift import"
MODULE="$SCRIPT_DIR/module"
rm -rf "$MODULE"
mkdir -p "$MODULE/vulkan"
VULKAN_HEADERS="$(find "$SRC" -path '*Vulkan-Headers/include/vulkan' -type d | head -1)"
if [ -n "$VULKAN_HEADERS" ]; then
    cp "$VULKAN_HEADERS"/*.h "$MODULE/vulkan/"
else
    # MoltenVK also ships core headers under MoltenVK/include when the
    # External fetch layout changed; fall back to any vulkan_core.h.
    FOUND="$(find "$SRC" -name 'vulkan_core.h' | head -1)"
    [ -n "$FOUND" ] || { echo "no Vulkan headers found in tree"; exit 1; }
    cp "$(dirname "$FOUND")"/*.h "$MODULE/vulkan/"
fi
cat > "$MODULE/module.modulemap" <<'EOF'
module Vulkan {
    header "vulkan/vulkan.h"
    export *
}
EOF

echo "==> Done."
ls -R "$OUT" | head -20
