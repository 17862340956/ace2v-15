#!/usr/bin/env python3
"""Verify the pinned source files that define this experiment's ABI assumptions."""
import hashlib
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_source.py KERNEL_SOURCE")
    manifest = json.loads((Path(__file__).resolve().parent / "source_reference.json").read_text(encoding="utf-8"))
    root = Path(sys.argv[1]).resolve()
    for item in manifest["files"]:
        path = root / item["path"]
        if not path.is_file():
            raise SystemExit("pinned source file missing: " + item["path"])
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != item["sha256"]:
            raise SystemExit("pinned source file differs: " + item["path"])
    print("Pinned 901 reference file hashes matched:", len(manifest["files"]))
    print("This validates listed files, not equivalence with the running 1301 kernel.")


if __name__ == "__main__":
    main()
