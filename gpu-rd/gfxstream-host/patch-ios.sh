#!/bin/bash
# Patch google/gfxstream's macOS-only includes so the iOS SDK build stands a
# chance (WP3 spike). libproc.h is absent from the iOS SDK while the symbol
# (proc_pidpath) exists in libSystem — declare it directly under
# TARGET_OS_IPHONE and keep the system include on macOS.
#
# Idempotent; applied to a fresh clone each CI run.
set -euo pipefail

SRC="${1:-gpu-rd/gfxstream-host/src}"
APPLY_STUBS="${2:-}"
[ -d "$SRC" ] || { echo "usage: $0 <gfxstream checkout dir> [ios]"; exit 1; }

python3 - "$SRC" <<'PYEOF'
import sys
from pathlib import Path

src = Path(sys.argv[1])
guard = (
    "#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE\n"
    "extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);\n"
    "#else\n"
    "#include <libproc.h>\n"
    "#endif"
)
changed = 0
for f in src.rglob('*'):
    if f.suffix not in ('.h', '.c', '.cpp', '.cc'):
        continue
    text = f.read_text(encoding='utf-8', errors='replace')
    if '#include <libproc.h>' in text:
        f.write_text(text.replace('#include <libproc.h>', guard), encoding='utf-8')
        changed += 1
print(f'patched {changed} file(s) referencing libproc.h')
PYEOF

# system-native-mac.mm: IOKit/AppKit (disk enums, dock icon, App Nap) do not
# exist on iOS. Replace the file's body with iOS stubs keeping the exact
# signatures the rest of gfxstream calls. Only on iOS legs: the macOS
# control build needs the real implementation.
if [ "$APPLY_STUBS" != "ios" ]; then
    echo 'macOS leg: keeping real system-native-mac.mm'
    exit 0
fi
python3 - "$SRC" <<'PYSTUB'
import sys
from pathlib import Path

src = Path(sys.argv[1])
target = src / 'common' / 'base' / 'system-native-mac.mm'
if target.exists():
    target.write_text(
        "// iOS stub for gfxstream common/base/system-native-mac.mm\n"
        "// (original uses IOKit/AppKit, which do not exist on iOS).\n"
        "#include <cstdint>\n"
        "#include <gfxstream/Optional.h>\n"
        "#include <gfxstream/system/Memory.h>\n"
        "\n"
        "namespace gfxstream {\n"
        "namespace base {\n"
        "\n"
        "void disableAppNap_macImpl(void) {}\n"
        "\n"
        "void cpuUsageCurrentThread_macImpl(uint64_t* user, uint64_t* sys) {\n"
        "    if (user) { *user = 0; }\n"
        "    if (sys) { *sys = 0; }\n"
        "}\n"
        "\n"
        "Optional<DiskKind> nativeDiskKind(int st_dev) {\n"
        "    (void)st_dev;\n"
        "    return {};\n"
        "}\n"
        "\n"
        "void hideDockIcon_macImpl(void) {}\n"
        "\n"
        "}  // namespace base\n"
        "}  // namespace gfxstream\n",
        encoding='utf-8')
    print('stubbed common/base/system-native-mac.mm for iOS')
else:
    print('system-native-mac.mm not found; upstream layout changed?')
PYSTUB

# native_window: the APPLE branch picks Cocoa (no Cocoa on iOS). Replace the
# whole file with iOS stubs keeping the exact signatures the backend calls.
python3 - "$SRC" <<'PYSTUB2'
import sys
from pathlib import Path

src = Path(sys.argv[1])
target = src / 'host' / 'native_window' / 'native_sub_window_cocoa.mm'
if target.exists():
    target.write_text(
        "// iOS stub for gfxstream native_window (Cocoa has no iOS analogue).\n"
        "// On iOS the embedding app hands the backend a CAMetalLayer-backed\n"
        "// view; sub-window management is a no-op around it.\n"
        "#include <stdio.h>\n"
        "#include <EGL/egl.h>\n"
        "#include \"gfxstream/host/native_sub_window.h\"\n"
        "\n"
        "EGLNativeWindowType createSubWindow(FBNativeWindowType p_window, int x, int y, int width,\n"
        "                                    int height, float dpr,\n"
        "                                    SubWindowRepaintCallback repaint_callback,\n"
        "                                    void* repaint_callback_param, int hideWindow) {\n"
        "    (void)x; (void)y; (void)width; (void)height; (void)dpr;\n"
        "    (void)repaint_callback; (void)repaint_callback_param; (void)hideWindow;\n"
        "    return (EGLNativeWindowType)p_window;\n"
        "}\n"
        "\n"
        "void destroySubWindow(EGLNativeWindowType win) {\n"
        "    (void)win;\n"
        "}\n"
        "\n"
        "int moveSubWindow(FBNativeWindowType p_parent_window, EGLNativeWindowType p_sub_window, int x,\n"
        "                  int y, int width, int height, float dpr) {\n"
        "    (void)p_parent_window; (void)p_sub_window;\n"
        "    (void)x; (void)y; (void)width; (void)height; (void)dpr;\n"
        "    return 0;\n"
        "}\n"
        "\n"
        "void* getNativeDisplay() {\n"
        "    return nullptr;\n"
        "}\n"
        "\n"
        "void* getMetalLayerFromView(void* view) {\n"
        "    return view;\n"
        "}\n",
        encoding='utf-8')
    print('stubbed host/native_window/native_sub_window_cocoa.mm for iOS')
else:
    print('native_sub_window_cocoa.mm not found; upstream layout changed?')
PYSTUB2

# testlibs: macOS-only test windowing (Cocoa) is built unconditionally;
# drop it on iOS (nothing else consumes it with tests disabled).
python3 - "$SRC" <<'PYSTUB3'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'host' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    if 'add_subdirectory(testlibs)' in text:
        text = text.replace('add_subdirectory(testlibs)',
                            '# iOS: testlibs (Cocoa OSXWindow) skipped\nif(NOT CMAKE_SYSTEM_NAME STREQUAL iOS)\nadd_subdirectory(testlibs)\nendif()')
        cmake.write_text(text, encoding='utf-8')
        print('guard testlibs behind non-iOS')
PYSTUB3

# Host GLES path: desktop-GL-based (glestranslator, mac_native) has no iOS
# analogue. Define GFXSTREAM_ENABLE_HOST_GLES=0 and skip the GL-only
# subdirectories; the Vulkan backend (the path games need) stays on.
# GL/GLES/EGL/KHR headers are vendored (shim-headers/) and staged into the
# source root, which is on every backend target's include path.

# Stage vendored headers into the source root (idempotent).
SHIM_SRC="$(dirname "$0")/shim-headers"
if [ -d "$SHIM_SRC" ]; then
    cp -R "$SHIM_SRC/GL" "$SHIM_SRC/GLES2" "$SHIM_SRC/GLES3" "$SHIM_SRC/EGL" "$SHIM_SRC/KHR" "$SRC/" 2>/dev/null || true
    echo "staged vendored GL/GLES/EGL/KHR headers into $SRC"
fi

# Header-only include dirs for skipped GLES subdirs whose headers the backend
# compiles against (frame_buffer.cpp -> gles2_dec -> gl_snapshot.h etc.).
python3 - "$SRC" <<'PYHDR'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'host' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    marker = 'SPGB_GLES_HEADER_DIRS'
    if marker not in text:
        anchor = '${GFXSTREAM_REPO_ROOT}'
        old = f'        {anchor}\n        ${{GFXSTREAM_REPO_ROOT}}/host\n'
        if old in text:
            add = (
                '        ${GFXSTREAM_REPO_ROOT}/host/gl/glsnapshot\n'
                '        ${GFXSTREAM_REPO_ROOT}/host/gl/gles1_dec\n'
                '        ${GFXSTREAM_REPO_ROOT}/host/gl/gles2_dec\n'
                '        ${GFXSTREAM_REPO_ROOT}/host/gl/OpenGLESDispatch/include\n'
                '        ${GFXSTREAM_REPO_ROOT}/host/gl/glestranslator/common/include\n'
            )
            # add only on iOS to keep other platforms untouched
            text = text.replace(old,
                '        ' + anchor + '\n'
                '        ${GFXSTREAM_REPO_ROOT}/host\n'
                '        if(CMAKE_SYSTEM_NAME STREQUAL iOS)\n'
                '        ' + add.rstrip() + '\n'
                '        endif()\n', 1)
            cmake.write_text(text, encoding='utf-8')
            print('backend include dirs: GLES header-only dirs added on iOS')
        else:
            print('WARNING: backend include anchor not found')
PYHDR
python3 - "$SRC" <<'PYGL'
import sys
from pathlib import Path

src = Path(sys.argv[1])
top = src / 'CMakeLists.txt'
if top.exists():
    # HOST_GLES stays =1 (upstream constant): the GL *sources* are skipped on
    # iOS, but backend headers take the EGL/GLES2 branch and compile against
    # the vendored shim headers. All GL calls sit behind the skipped
    # EmulationGL pimpl, so no GL symbols are referenced from retained code.
    print('top CMakeLists: HOST_GLES left at =1 (vendored shim headers provide GLES/EGL)')
gl = src / 'host' / 'gl' / 'CMakeLists.txt'
if gl.exists():
    text = gl.read_text(encoding='utf-8')
    # OpenGLESDispatch MUST build on iOS too: the backend's headers include
    # its dispatch headers unconditionally (emulation_gl.h). It is
    # dlopen-based at runtime, so it compiles without a host GL present.
    for sub in ('glestranslator', 'glsnapshot',
                'gles1_dec', 'gles2_dec'):
        text = text.replace(f'add_subdirectory({sub})',
            f'if(NOT CMAKE_SYSTEM_NAME STREQUAL iOS)\nadd_subdirectory({sub})\nendif()')
    gl.write_text(text, encoding='utf-8')
    print('gl/CMakeLists: translator+snapshot skipped on iOS')
PYGL

# Vulkan-only backend: drop gfxstream-gl-server (and the GLES translator libs)
# from gfxstream_backend_static's link when HOST_GLES is disabled on iOS.
python3 - "$SRC" <<'PYLINK'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'host' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    changed = 0
    nl = chr(10)
    for lib in ('gfxstream-gl-server', 'GLES_CM_translator_static', 'renderControl_dec'):
        tgt = f'        {lib}{nl}'
        if tgt in text:
            # target_link_libraries is not flow control: use a generator
            # expression so the lib drops out on iOS.
            text = text.replace(tgt,
                '        $<$<NOT:$<PLATFORM_ID:iOS>>:' + lib + '>' + nl)
            changed += 1
    cmake.write_text(text, encoding='utf-8')
    print(f'dropped {changed} GL-only libs from backend link on iOS')
PYLINK

# gl-server: don't even build it on iOS (backend no longer links it; its
# sources include the skipped GLES dispatch headers).
python3 - "$SRC" <<'PYGLSRV'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'host' / 'gl' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    needle = 'add_library(gfxstream-gl-server'
    if needle in text and 'SPGB_IOS_SKIP_GL_SERVER' not in text:
        nl = chr(10)
        text = text.replace(needle,
            'if(NOT CMAKE_SYSTEM_NAME STREQUAL iOS)' + nl + needle)
        # close the gl-server guard conditional itself
        text += (nl + 'endif()' + nl +
                 '# SPGB_IOS_SKIP_GL_SERVER: gl-server target skipped on iOS' + nl)
        cmake.write_text(text, encoding='utf-8')
        print('gl-server build guarded on iOS (SPGB_IOS_SKIP_GL_SERVER)')
PYGLSRV

# OpenGLESDispatch PUBLIC-links the skipped decoders; make them drop out on
# iOS with the same generator expressions (dispatch is dlopen-based, the
# vulkan path never calls them).
python3 - "$SRC" <<'PYOGD'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'host' / 'gl' / 'OpenGLESDispatch' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    nl = chr(10)
    changed = 0
    for lib in ('gles1_dec', 'gles2_dec', 'EGL_translator_static'):
        for tgt in (f'    {lib}{nl}', f'    {lib})'):
            repl = ('    $<$<NOT:$<PLATFORM_ID:iOS>>:' + lib + '>' +
                    (nl if tgt.endswith(nl) else ')'))
            if tgt in text:
                text = text.replace(tgt, repl)
                changed += 1
                break
    cmake.write_text(text, encoding='utf-8')
    print(f'OpenGLESDispatch: dropped {changed} decoder libs on iOS')
PYOGD

# APPLE frameworks: iOS has QuartzCore + IOSurface (the Metal presentation
# path) but no AppKit. Split the link accordingly.
python3 - "$SRC" <<'PYFW'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'host' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    old = ('if (APPLE)\n'
           '    target_link_libraries(gfxstream_backend_static PUBLIC "-framework AppKit -framework QuartzCore -framework IOSurface")\n'
           'endif()')
    new = ('if (APPLE)\n'
           '    if(CMAKE_SYSTEM_NAME STREQUAL iOS)\n'
           '        target_link_libraries(gfxstream_backend_static PUBLIC "-framework QuartzCore -framework IOSurface")\n'
           '    else()\n'
           '        target_link_libraries(gfxstream_backend_static PUBLIC "-framework AppKit -framework QuartzCore -framework IOSurface")\n'
           '    endif()\n'
           'endif()')
    if old in text:
        text = text.replace(old, new)
        cmake.write_text(text, encoding='utf-8')
        print('backend frameworks: AppKit dropped on iOS (QuartzCore+IOSurface kept)')
    else:
        print('framework block not found/already patched')
PYFW

# common/base: its APPLE platform deps include AppKit + IOKit (neither on
# iOS; IOKit-as-framework is macOS-only, iOS has IOKit headers partially).
python3 - "$SRC" <<'PYCB'
import sys
from pathlib import Path

src = Path(sys.argv[1])
cmake = src / 'common' / 'base' / 'CMakeLists.txt'
if cmake.exists():
    text = cmake.read_text(encoding='utf-8')
    old = ('elseif(APPLE)\n'
           '    set(gfxstream_common_base_platform_deps\n'
           '        "-framework Foundation"\n'
           '        "-framework AppKit"\n'
           '        "-framework IOKit")\n'
           'endif()')
    new = ('elseif(APPLE)\n'
           '    if(CMAKE_SYSTEM_NAME STREQUAL iOS)\n'
           '        set(gfxstream_common_base_platform_deps\n'
           '            "-framework Foundation")\n'
           '    else()\n'
           '        set(gfxstream_common_base_platform_deps\n'
           '            "-framework Foundation"\n'
           '            "-framework AppKit"\n'
           '            "-framework IOKit")\n'
           '    endif()\n'
           'endif()')
    if old in text:
        text = text.replace(old, new)
        cmake.write_text(text, encoding='utf-8')
        print('common/base: iOS platform deps = Foundation only')
    else:
        print('common/base block not found or already patched')
PYCB