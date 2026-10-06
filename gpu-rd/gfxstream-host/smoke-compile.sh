#!/bin/bash
# Local/CI smoke compile of the gfxstream iOS-patched sources.
#
# Compiles the backend TUs that failed during the iOS port against the
# patched tree with the shim headers, WITHOUT needing a mac: any host with
# g++ works (Windows: use WSL). Purpose: iterate the include-graph cascade
# in seconds instead of 20-minute CI rounds.
#
# Usage: bash smoke-compile.sh <patched-gfxstream-src> [shim-headers-dir]
# Exit 0 = every smoke TU compiles.

set -uo pipefail

SRC="${1:?usage: smoke-compile.sh <patched-gfxstream-src> [shim-headers-dir]}"
SHIM="${2:-$(dirname "$0")/shim-headers}"

INC=(
    -I "$SRC"
    -I "$SRC/include"
    -I "$SRC/host"
    -I "$SRC/host/include"
    -I "$SRC/host/gl"
    -I "$SRC/host/gl/OpenGLESDispatch/include"
    -I "$SRC/host/gl/glsnapshot"
    -I "$SRC/host/gl/gles1_dec"
    -I "$SRC/host/gl/gles2_dec"
    -I "$SRC/host/common/include"
    -I "$SRC/host/features/include"
    -I "$SRC/host/decoder_common/include"
    -I "$SRC/host/iostream/include"
    -I "$SRC/host/renderControl_dec"
    -I "$SRC/host/library/include"
    -I "$SRC/host/vulkan/cereal"
    -I "$SRC/host/vulkan/cereal/common"
    -I "$SRC/host/gl/glestranslator/common/include"
    -I "$SRC/host/native_window/include"
    -I "$SRC/host/tracing/include"
    -I "$SRC/host/vulkan"
    -I "$SRC/third_party/vulkan/include"
    -I "$SRC/host/renderdoc/include"
    -I "$SRC/common/base/include"
    -I "$SRC/common/logging/include"
    -I "$SRC/common/utils/include"
    -I "$SRC/common"
    -I "$SRC/host/address_space/include"
    -I "$SRC/host/compressed_textures/include"
    -I "$SRC/host/gfxstream_host_decoder_common"
    -I "$SHIM/vulkan"
    -I "$SHIM"
    -I "$SRC/third_party/glm/include"
)

DEFINES=(-DGFXSTREAM_ENABLE_HOST_GLES=1 -DGFXSTREAM_SPGB_IOS=1)

# TUs that anchor the include-graph cascade (extend as new ones surface).
TUS=(
    src/host/frame_buffer.cpp
    src/host/Buffer.cpp
    src/host/color_buffer.cpp
    src/host/gl/OpenGLESDispatch/EGLDispatch.cpp
    src/host/gl/OpenGLESDispatch/GLESv2Dispatch.cpp
)

FAIL=0
for tu in "${TUS[@]}"; do
    if g++ -fsyntax-only -std=c++17 "${DEFINES[@]}" "${INC[@]}" "$tu" 2>/tmp/spgb-smoke-last.log; then
        echo "OK   $tu"
    else
        echo "FAIL $tu"
        head -6 /tmp/spgb-smoke-last.log
        FAIL=1
    fi
done
exit $FAIL
