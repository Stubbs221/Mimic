#!/usr/bin/env python3
# Created by Василий Маслов on 05.10.2026.
"""Create a portable .mimicprofile ZIP; no machine settings or credentials are included."""
import argparse
import json
import pathlib
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("source", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
root = args.source.resolve()
manifest = root / "profile.json"
json.loads(manifest.read_text())
files = [manifest] + sorted((root / "adapters").rglob("*"))
files = [path for path in files if path.is_file()]
if len(files) > 512 or sum(path.stat().st_size for path in files) > 32 * 1024 * 1024:
    raise SystemExit("Profile exceeds import limits")
if any(path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != root.parent) for path in files):
    raise SystemExit("Symlinks are not supported")
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, path.relative_to(root).as_posix())
print(args.output)
