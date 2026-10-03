#!/usr/bin/env python3
"""Inject DroidDeck sources into UTM.xcodeproj's iOS app targets.

The fork keeps UTM's classic (non-synchronized) project format, so new Swift
files must be registered in four places: PBXFileReference, PBXBuildFile (one
per target), a PBXGroup entry under Platform/, and the Sources build phase of
each app target ("iOS" and "iOS-SE").

The script is idempotent: files already present are skipped. UUIDs are derived
deterministically from the file path, so re-runs do not duplicate entries.

Usage: python3 scripts/inject_droiddeck.py [additional.swift ...]
"""

import hashlib
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "UTM.xcodeproj" / "project.pbxproj"
APP_TARGETS = ("iOS", "iOS-SE")

# (path relative to repo root, group subpath relative to the DroidDeck group)
BASE = Path("Platform/DroidDeck")
FILES = [
    ("DroidDeckHardware.swift", ""),
    ("DroidDeckVMBuilder.swift", ""),
    ("DroidDeckOSManager.swift", ""),
    ("DroidDeckHomeView.swift", ""),
    ("DroidDeckSettingsView.swift", ""),
    ("DroidDeckAboutView.swift", ""),
    ("Streaming/MoonlightDiscovery.swift", "Streaming"),
    ("Streaming/MoonlightSessionView.swift", "Streaming"),
    ("GPUBridge/SPGBTypes.swift", "GPUBridge"),
    ("GPUBridge/SPGBHostRenderer.swift", "GPUBridge"),
    ("GPUBridge/SPGBGuestSimulator.swift", "GPUBridge"),
    ("GPUBridge/GPUBridgeDiagnosticsView.swift", "GPUBridge"),
]


def uuid_for(name: str) -> str:
    digest = hashlib.sha1(f"droiddeck:{name}".encode()).hexdigest()[:24].upper()
    return digest


def native_target_sources_phase(txt: str, target_name: str) -> str:
    """Return the Sources build phase UUID for a PBXNativeTarget."""
    pattern = re.compile(
        r"([0-9A-F]{24}) /\* " + re.escape(target_name) +
        r" \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
        re.S,
    )
    for uuid, body in pattern.findall(txt):
        m = re.search(r"([0-9A-F]{24}) /\* Sources \*/", body)
        if m:
            return m.group(1)
    raise SystemExit(f"could not find Sources phase for target {target_name}")


def insert_after(txt: str, marker: str, addition: str) -> str:
    idx = txt.find(marker)
    if idx < 0:
        raise SystemExit(f"marker not found: {marker}")
    idx += len(marker)
    return txt[:idx] + addition + txt[idx:]


def insert_into_files_list(txt: str, phase_uuid: str, entry: str) -> str:
    """Append an entry to the files = (...) list of a build phase."""
    pattern = re.compile(
        re.escape(phase_uuid) + r" /\* Sources \*/ = \{[^}]*?files = \(",
        re.S,
    )
    m = pattern.search(txt)
    if not m:
        raise SystemExit(f"files list not found for phase {phase_uuid}")
    idx = m.end()
    return txt[:idx] + "\n" + entry + txt[idx:]


def insert_into_group_children(txt: str, group_uuid: str, entry: str) -> str:
    pattern = re.compile(
        re.escape(group_uuid) + r" /\* [^*]+ \*/ = \{\s*isa = PBXGroup;\s*children = \(",
        re.S,
    )
    m = pattern.search(txt)
    if not m:
        raise SystemExit(f"children list not found for group {group_uuid}")
    idx = m.end()
    return txt[:idx] + "\n" + entry + txt[idx:]


def find_group_uuid(txt: str, name: str) -> str:
    pattern = re.compile(
        r"([0-9A-F]{24}) /\* " + re.escape(name) +
        r" \*/ = \{\s*isa = PBXGroup;",
    )
    m = pattern.search(txt)
    if not m:
        raise SystemExit(f"group not found: {name}")
    return m.group(1)


def main() -> None:
    txt = PROJECT.read_text(encoding="utf-8")

    extra_args = sys.argv[1:]
    files = list(FILES)
    for arg in extra_args:
        rel = Path(arg)
        try:
            sub = rel.relative_to(BASE).parent
        except ValueError:
            continue  # outside Platform/DroidDeck; ignore
        entry = (str(rel.relative_to(BASE)), "" if str(sub) == "." else str(sub))
        if entry not in files:
            files.append(entry)

    for rel_path, _ in files:
        if not (PROJECT.parent.parent / BASE / rel_path).exists():
            raise SystemExit(f"missing source file: {BASE / rel_path}")

    platform_group = find_group_uuid(txt, "Platform")
    droiddeck_group = uuid_for("group:DroidDeck")
    sources_phases = {t: native_target_sources_phase(txt, t) for t in APP_TARGETS}

    changed = False

    # 1. Group children: register DroidDeck under Platform (once).
    if f"{droiddeck_group} /* DroidDeck */" not in txt:
        txt = insert_into_group_children(
            txt, platform_group, f"\t\t\t\t{droiddeck_group} /* DroidDeck */,")
        changed = True

    # 2. Group definitions: root group once, then each subgroup independently
    #    (so later additions create their own subgroup without touching the rest).
    if f"{droiddeck_group} /* DroidDeck */ = {{\n" not in txt:
        root_files = [p for p, sub in files if not sub]
        children = [f"\t\t\t\t{uuid_for('ref:' + p)} /* {Path(p).name} */," for p in root_files]
        block = (
            f"\n\t\t{droiddeck_group} /* DroidDeck */ = {{\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n" + "\n".join(children) + "\n\t\t\t);\n"
            "\t\t\tpath = DroidDeck;\n"
            "\t\t\tsourceTree = \"<group>\";\n"
            "\t\t};\n"
        )
        txt = insert_after(txt, "/* Begin PBXGroup section */", block)
        changed = True

    for sub in sorted({sub for _, sub in files if sub}):
        sub_group = uuid_for("group:" + sub)
        if f"{sub_group} /* {sub} */ = {{\n" not in txt:
            sub_files = [p for p, s in files if s == sub]
            schildren = [f"\t\t\t\t{uuid_for('ref:' + p)} /* {Path(p).name} */," for p in sub_files]
            block = (
                f"\n\t\t{sub_group} /* {sub} */ = {{\n"
                "\t\t\tisa = PBXGroup;\n"
                "\t\t\tchildren = (\n" + "\n".join(schildren) + "\n\t\t\t);\n"
                f"\t\t\tpath = {sub};\n"
                "\t\t\tsourceTree = \"<group>\";\n"
                "\t\t};\n"
            )
            txt = insert_after(txt, "/* Begin PBXGroup section */", block)
            # also list the subgroup as a child of the root group
            if f"{sub_group} /* {sub} */," not in txt:
                txt = insert_into_group_children(
                    txt, droiddeck_group, f"\t\t\t\t{sub_group} /* {sub} */,")
            changed = True

    # 3. File references + build files + sources phase entries.
    for rel_path, _ in files:
        ref = uuid_for("ref:" + rel_path)
        name = Path(rel_path).name
        if f"{ref} /* {name} */ = {{isa = PBXFileReference" in txt:
            continue
        txt = insert_after(
            txt,
            "/* Begin PBXFileReference section */",
            f"\n\t\t{ref} /* {name} */ = {{isa = PBXFileReference; fileEncoding = 4; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};",
        )
        for target in APP_TARGETS:
            build = uuid_for(f"build:{target}:{rel_path}")
            txt = insert_after(
                txt,
                "/* Begin PBXBuildFile section */",
                f"\n\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};",
            )
            txt = insert_into_files_list(
                txt, sources_phases[target],
                f"\t\t\t\t{build} /* {name} in Sources */,")
        changed = True

    if changed:
        PROJECT.write_text(txt, encoding="utf-8", newline="\n")
        print(f"injected {len(files)} files into targets {APP_TARGETS}")
    else:
        print("nothing to do; all files already present")


if __name__ == "__main__":
    main()
