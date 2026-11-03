#!/usr/bin/env python3
"""Adds or updates entries in the iPhone app's string catalogue, written the way Xcode writes it.

    python scripts/xcstrings.py strings.json      # {"English key": {"zh-Hans": "…", "zh-Hant": "…"}, …}
    python scripts/xcstrings.py --check            # exit 1 when the file is not in Xcode's layout

The English text is the key (AppLocalized looks it up by its English); an entry gets an "en"
unit with the key itself plus the translations given. Existing translations of other
languages are kept. The catalogue keeps Xcode's layout (two-space indent, " : ", an empty
object as an empty line), so a diff shows only the strings that changed.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

CATALOGUE = Path(__file__).resolve().parent.parent / "android/src/ios/Localizable.xcstrings"


def dump(value, indent: int = 0) -> str:
    pad = "  " * indent
    inner = "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + pad + "}"
        items = [f"{inner}{json.dumps(k, ensure_ascii=False)} : {dump(v, indent + 1)}" for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + pad + "]"
        items = [inner + dump(v, indent + 1) for v in value]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


def sort_key(key: str):
    return key.casefold(), key


def merge(existing: dict, added: dict) -> dict:
    """Existing entries keep Xcode's order; a new key goes before the first existing key it sorts before."""
    pending = sorted((k for k in added if k not in existing), key=sort_key)
    out = {}
    for key, value in existing.items():
        while pending and sort_key(pending[0]) < sort_key(key):
            k = pending.pop(0)
            out[k] = added[k]
        out[key] = added.get(key, value)
    for k in pending:
        out[k] = added[k]
    return out


def write(data: dict) -> str:
    return dump(data) + "\n"


def main() -> int:
    raw = CATALOGUE.read_text(encoding="utf-8")
    data = json.loads(raw)
    if sys.argv[1:] == ["--check"]:
        return 0 if write(json.loads(raw)) == raw else 1
    additions = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    entries = {}
    for key, translations in additions.items():
        entry = json.loads(json.dumps(data["strings"].get(key, {})))
        entry["extractionState"] = "manual"
        units = entry.get("localizations", {})
        for lang, text in {"en": key, **translations}.items():
            units[lang] = {"stringUnit": {"state": "translated", "value": text}}
        entry["localizations"] = dict(sorted(units.items()))
        entries[key] = entry
    data["strings"] = merge(data["strings"], entries)
    CATALOGUE.write_text(write(data), encoding="utf-8", newline="\n")
    print(f"{len(additions)} strings written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
