#!/usr/bin/env python3
"""Report String Catalog keys that have no Spanish (es) translation.

Run from the repository root: `python3 scripts/check_es.py`. Exits 1 when any key is missing `es`.
Stale keys and keys marked "shouldTranslate": false are skipped.
"""
import json
import pathlib
import sys

missing = []
for path in sorted(pathlib.Path(".").glob("**/*.xcstrings")):
    if "DerivedData" in path.parts or ".build" in path.parts:
        continue
    strings = json.loads(path.read_text(encoding="utf-8")).get("strings", {})
    for key, entry in strings.items():
        if not key.strip() or entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        if "es" not in entry.get("localizations", {}):
            missing.append(f"{path}: {key!r}")

for line in missing:
    print(line)
print(f"{len(missing)} missing")
sys.exit(1 if missing else 0)
