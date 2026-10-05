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
