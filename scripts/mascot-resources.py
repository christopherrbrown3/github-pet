#!/usr/bin/env python3
"""Stage and verify the bundled runtime files of the built-in mascot packs."""

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil

PACKS = {"mona-pet-v1": 12, "little-chris-v1": 9}
STATES = {"idle", "attention", "urgent"}
# Schema v2 (#138): optional held states, clips and accessories, under the bundled design budget.
HELD = {"drag", "doze"}
RUNTIME_DIRS = {"frames", "accessories"}
MAX_IMAGES = 64
MAX_IMAGE_BYTES = 96 * 1024
MAX_PACK_BYTES = 4 * 1024 * 1024


def runtime_paths(pack, expected_id, expected_frames):
    manifest = pack / "manifest.json"
    frames_dir = pack / "frames"
    if pack.is_symlink() or manifest.is_symlink() or frames_dir.is_symlink():
        raise ValueError(f"{pack}: runtime paths must not be symlinks")
    if not manifest.is_file() or manifest.stat().st_size > 256 * 1024:
        raise ValueError(f"{manifest}: missing or oversized runtime manifest")
    data = json.loads(manifest.read_text())
    version = data.get("schemaVersion")
    if data.get("id") != expected_id or version not in (1, 2):
        raise ValueError(f"{manifest}: expected {expected_id} schema v1 or v2")
    states = data["states"]
    allowed = STATES | (HELD if version == 2 else set())
    if not STATES <= set(states) or not set(states) <= allowed:
        raise ValueError(f"{manifest}: expected idle, attention and urgent states" + (" (plus drag, doze)" if version == 2 else ""))
    sequences = [[*state["frames"], state["staticFallback"]] for state in states.values()]
    if version == 2:
        sequences += [clip["frames"] for clip in data.get("clips", {}).values()]
        sequences += [[accessory["image"]] for accessory in data.get("accessories", {}).values()]
    paths = set()
    for names in sequences:
        if not isinstance(names, list) or not names:
            raise ValueError(f"{manifest}: empty or invalid frame list")
        for name in names:
            relative = PurePosixPath(name)
            if len(relative.parts) != 2 or relative.parts[0] not in RUNTIME_DIRS or relative.suffix != ".png":
                raise ValueError(f"{manifest}: invalid runtime frame path {name!r}")
            frame = pack / relative
            if frame.is_symlink() or not frame.is_file() or frame.stat().st_size > MAX_IMAGE_BYTES:
                raise ValueError(f"{manifest}: invalid runtime frame {name!r} (missing, a link, or over 96 KiB)")
            paths.add(relative.as_posix())
    if len(paths) > MAX_IMAGES or sum((pack / path).stat().st_size for path in paths) > MAX_PACK_BYTES:
        raise ValueError(f"{manifest}: over the bundled budget ({MAX_IMAGES} images, 4 MiB)")
    if version == 1 and len(paths) != expected_frames:
        raise ValueError(f"{manifest}: expected {expected_frames} runtime frames, found {len(paths)}")
    return {"manifest.json", *paths}


def verify(root):
    if {path.name for path in root.iterdir()} != set(PACKS):
        raise ValueError(f"{root}: expected exactly the two built-in packs")
    for pack_id, count in PACKS.items():
        pack = root / pack_id
        files = runtime_paths(pack, pack_id, count)
        expected = files | {PurePosixPath(path).parts[0] for path in files if "/" in path}
        actual = {path.relative_to(pack).as_posix() for path in pack.rglob("*")}
        if actual != expected:
            raise ValueError(f"{pack}: bundled files differ from manifest runtime files")
        print(f"{pack_id}: verified manifest and {len(files) - 1} runtime images")


def stage(source, destination):
    packs = {pack_id: runtime_paths(source / pack_id, pack_id, count) for pack_id, count in PACKS.items()}
    destination.mkdir(parents=True)
    for pack_id, paths in packs.items():
        for directory in sorted({PurePosixPath(path).parent for path in paths} - {PurePosixPath(".")}):
            (destination / pack_id / directory).mkdir(parents=True, exist_ok=True)
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
