#!/usr/bin/env python3
"""Stage and verify the bundled runtime files of the built-in mascot packs."""

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil

PACKS = {"mona-pet-v1": 12, "little-chris-v1": 9}
STATES = {"idle", "attention", "urgent"}


def runtime_paths(pack, expected_id, expected_frames):
    manifest = pack / "manifest.json"
    frames_dir = pack / "frames"
    if pack.is_symlink() or manifest.is_symlink() or frames_dir.is_symlink():
        raise ValueError(f"{pack}: runtime paths must not be symlinks")
    if not manifest.is_file() or manifest.stat().st_size > 256 * 1024:
        raise ValueError(f"{manifest}: missing or oversized runtime manifest")
    data = json.loads(manifest.read_text())
    if data.get("id") != expected_id or data.get("schemaVersion") != 1:
        raise ValueError(f"{manifest}: expected {expected_id} schema v1")
    states = data["states"]
    if set(states) != STATES:
        raise ValueError(f"{manifest}: expected idle, attention and urgent states")
    paths = set()
    for state in states.values():
        frames = state["frames"]
        if not isinstance(frames, list) or not frames:
            raise ValueError(f"{manifest}: empty or invalid frame list")
        for name in [*frames, state["staticFallback"]]:
            relative = PurePosixPath(name)
            if len(relative.parts) != 2 or relative.parts[0] != "frames" or relative.suffix != ".png":
                raise ValueError(f"{manifest}: invalid runtime frame path {name!r}")
            frame = pack / relative
            if frame.is_symlink() or not frame.is_file() or frame.stat().st_size > 4 * 1024 * 1024:
                raise ValueError(f"{manifest}: invalid runtime frame {name!r}")
            paths.add(relative.as_posix())
    if len(paths) != expected_frames:
        raise ValueError(f"{manifest}: expected {expected_frames} runtime frames, found {len(paths)}")
    return {"manifest.json", *paths}


def verify(root):
    if {path.name for path in root.iterdir()} != set(PACKS):
        raise ValueError(f"{root}: expected exactly the two built-in packs")
    for pack_id, count in PACKS.items():
        pack = root / pack_id
        expected = runtime_paths(pack, pack_id, count) | {"frames"}
        actual = {path.relative_to(pack).as_posix() for path in pack.rglob("*")}
        if actual != expected:
            raise ValueError(f"{pack}: bundled files differ from manifest runtime files")
        print(f"{pack_id}: verified manifest and {count} runtime frames")


def stage(source, destination):
    packs = {pack_id: runtime_paths(source / pack_id, pack_id, count) for pack_id, count in PACKS.items()}
    destination.mkdir(parents=True)
    for pack_id, paths in packs.items():
        (destination / pack_id / "frames").mkdir(parents=True)
        for relative in sorted(paths):
            shutil.copyfile(source / pack_id / relative, destination / pack_id / relative)
    verify(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    copy = commands.add_parser("stage")
    copy.add_argument("source", type=Path)
    copy.add_argument("destination", type=Path)
    check = commands.add_parser("verify")
    check.add_argument("root", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "stage":
            stage(args.source, args.destination)
        else:
            verify(args.root)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        parser.exit(1, f"mascot resources: {error}\n")


if __name__ == "__main__":
    main()
