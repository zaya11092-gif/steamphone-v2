#!/usr/bin/env python3
"""Link MoltenVK.xcframework into UTM.xcodeproj's iOS app targets.

Used by the CI MoltenVK profile (vulkan-track.yml) after gpu-rd/moltenvk/
build.sh has produced gpu-rd/moltenvk/build/MoltenVK.xcframework. Static
framework: link-only, no embed, no rpath. Also sets SWIFT_INCLUDE_PATHS so
`import Vulkan` resolves the module staged by build.sh.

Idempotent; run from the repository root:
    python3 scripts/link_moltenvk.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "UTM.xcodeproj" / "project.pbxproj"
FRAMEWORK_REL = "gpu-rd/moltenvk/build/MoltenVK.xcframework"
MODULE_REL = "gpu-rd/moltenvk/module"
APP_TARGETS = ("iOS", "iOS-SE")

# Deterministic UUIDs (24 hex chars), same scheme as inject_droiddeck.py.
import hashlib

def uuid_for(name: str) -> str:
    return hashlib.sha1(f"droiddeck:{name}".encode()).hexdigest()[:24].upper()


def native_target_frameworks_phase(txt: str, target_name: str) -> str:
    pattern = re.compile(
        r"([0-9A-F]{24}) /\* " + re.escape(target_name) +
        r" \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
        re.S,
    )
    for uuid, body in pattern.findall(txt):
        m = re.search(r"([0-9A-F]{24}) /\* Frameworks \*/", body)
        if m:
            return m.group(1)
    raise SystemExit(f"could not find Frameworks phase for target {target_name}")


def insert_into_files_list(txt: str, phase_uuid: str, entry: str) -> str:
    pattern = re.compile(
        re.escape(phase_uuid) + r" /\* Frameworks \*/ = \{[^}]*?files = \(",
        re.S,
    )
    m = pattern.search(txt)
    if not m:
        raise SystemExit(f"files list not found for phase {phase_uuid}")
    idx = m.end()
    return txt[:idx] + "\n" + entry + txt[idx:]


def insert_after(txt: str, marker: str, addition: str) -> str:
    idx = txt.find(marker)
    if idx < 0:
        raise SystemExit(f"marker not found: {marker}")
    idx += len(marker)
    return txt[:idx] + addition + txt[idx:]


def add_swift_include_path(txt: str) -> str:
    """Insert SWIFT_INCLUDE_PATHS before every SWIFT_VERSION assignment so
    all build configurations (Debug/Release/etc.) resolve the module."""
    if MODULE_REL in txt:
        return txt
    marker = "SWIFT_VERSION = "
    positions = []
    idx = txt.find(marker)
    while idx >= 0:
        positions.append(idx)
        idx = txt.find(marker, idx + len(marker))
    if not positions:
        print("warning: no SWIFT_VERSION settings found; SWIFT_INCLUDE_PATHS not set")
        return txt
    # Insert before each occurrence (reverse order keeps offsets valid).
    for pos in reversed(positions):
        line_start = txt.rfind("\n", 0, pos) + 1
        indent = txt[line_start:pos]
        addition = f"{indent}SWIFT_INCLUDE_PATHS = {MODULE_REL};\n"
        txt = txt[:line_start] + addition + txt[line_start:]
    return txt


def main() -> None:
    if not (ROOT / FRAMEWORK_REL).exists():
        raise SystemExit(f"missing {FRAMEWORK_REL}; run gpu-rd/moltenvk/build.sh first")
    if not (ROOT / MODULE_REL / "module.modulemap").exists():
        raise SystemExit(f"missing {MODULE_REL}/module.modulemap; run gpu-rd/moltenvk/build.sh first")

    txt = PROJECT.read_text(encoding="utf-8")
    ref = uuid_for("xcframework:MoltenVK")
    name = "MoltenVK.xcframework"

    if f"{ref} /* {name} */ = {{isa = PBXFileReference" in txt:
        print("MoltenVK already linked; nothing to do")
        return

    file_ref = (
        f"\n\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = wrapper.xcframework; path = \"{FRAMEWORK_REL}\"; "
        f"sourceTree = SOURCE_ROOT; }};"
    )
    txt = insert_after(txt, "/* Begin PBXFileReference section */", file_ref)

    for target in APP_TARGETS:
        build = uuid_for(f"framework-build:{target}:MoltenVK")
        build_ref = (
            f"\n\t\t{build} /* {name} in Frameworks */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};"
        )
        txt = insert_after(txt, "/* Begin PBXBuildFile section */", build_ref)
        phase = native_target_frameworks_phase(txt, target)
        txt = insert_into_files_list(
            txt, phase, f"\t\t\t\t{build} /* {name} in Frameworks */,")

    txt = add_swift_include_path(txt)
    PROJECT.write_text(txt, encoding="utf-8", newline="\n")
    print(f"linked {name} into {APP_TARGETS} + SWIFT_INCLUDE_PATHS={MODULE_REL}")


if __name__ == "__main__":
    main()
