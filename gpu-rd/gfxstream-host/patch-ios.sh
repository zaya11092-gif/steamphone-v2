#!/bin/bash
# Patch google/gfxstream's macOS-only includes so the iOS SDK build stands a
# chance (WP3 spike). libproc.h is absent from the iOS SDK while the symbol
# (proc_pidpath) exists in libSystem — declare it directly under
# TARGET_OS_IPHONE and keep the system include on macOS.
#
# Idempotent; applied to a fresh clone each CI run.
set -euo pipefail

SRC="${1:-gpu-rd/gfxstream-host/src}"
[ -d "$SRC" ] || { echo "usage: $0 <gfxstream checkout dir>"; exit 1; }

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
