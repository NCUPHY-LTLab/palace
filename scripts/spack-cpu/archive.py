#!/usr/bin/env python3
"""Validate and extract one trusted-by-checksum tar archive without path escape."""

import argparse
import os
import tarfile
from pathlib import Path, PurePosixPath


def safe_relative(name):
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.destination.exists():
        raise RuntimeError("extraction destination already exists: {0}".format(args.destination))

    seen = set()
    with tarfile.open(str(args.archive), "r:*") as bundle:
        for member in bundle.getmembers():
            if not safe_relative(member.name) or member.name in seen:
                raise RuntimeError("unsafe or duplicate archive path: {0}".format(member.name))
            seen.add(member.name)
            if member.isdev() or member.isfifo():
                raise RuntimeError("unsupported archive entry: {0}".format(member.name))
            if member.issym() or member.islnk():
                parent = PurePosixPath(member.name).parent
                target = PurePosixPath(os.path.normpath(str(parent / member.linkname)))
                if not safe_relative(str(target)):
                    raise RuntimeError("archive link escapes destination: {0}".format(member.name))
        args.destination.mkdir(parents=True)
        bundle.extractall(str(args.destination))


if __name__ == "__main__":
    main()
