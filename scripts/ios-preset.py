#!/usr/bin/env python3
"""Writes the iPhone app's copy of the personal build's presets.

The Android app ships its starting state under assets/preset/: the skills it installs (a course
is a folder: SKILL.md, books/B01..B10), the agent's files about its owner and the coach's
steering sentence. The iPhone app bundles NanoMuse/ as a synchronized folder, which flattens
resources, so seven SKILL.md files cannot sit side by side there. This script packs the tree
into one JSON file, NanoMuse/Resources/preset.json, as {"files": {"skills/<id>/SKILL.md": text,
...}}; NanoMusePreset.swift installs from it.

    python scripts/ios-preset.py           # write it
    python scripts/ios-preset.py --check   # exit 1 when the copy is stale
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "android/src/android/app/src/main/assets/preset"
TARGET = ROOT / "android/src/ios/NanoMuse/Resources/preset.json"


def render() -> str:
    files = {}
    for path in sorted(SOURCE.rglob("*")):
        if path.is_file():
            files[path.relative_to(SOURCE).as_posix()] = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    return json.dumps({"files": files}, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def main() -> int:
    text = render()
    if "--check" in sys.argv[1:]:
        current = TARGET.read_text(encoding="utf-8") if TARGET.exists() else ""
        if current != text:
            print(f"{TARGET.relative_to(ROOT)} is stale: run python scripts/ios-preset.py")
            return 1
        return 0
    TARGET.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {TARGET.relative_to(ROOT)}: {len(json.loads(text)['files'])} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
