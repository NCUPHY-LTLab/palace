#!/usr/bin/env python3
"""Verify immutable preparation and installation receipts."""

import argparse
import hashlib
import json
import os
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_manifest(path):
    for line in path.read_text().splitlines():
        expected, name = line.split("  ", 1)
        target = Path(name)
        if not target.is_file() or sha256(target) != expected:
            raise RuntimeError("manifest mismatch: {0}".format(target))


def verify_links(root, receipt):
    lines = []
    for path in sorted(root.rglob("*"), key=lambda item: str(item)):
        if path.is_symlink():
            lines.append("{0} -> {1}\n".format(path, os.readlink(str(path))))
    actual = hashlib.sha256("".join(lines).encode()).hexdigest()
    expected = receipt.read_text().split()[0]
    if actual != expected:
        raise RuntimeError("symbolic-link manifest mismatch: {0}".format(root))


def verify_prepared(preparation, plan_key=None):
    receipt_path = preparation / "PREPARED.json"
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("state") != "PREPARED":
        raise RuntimeError("preparation is not complete")
    if plan_key is not None and receipt.get("plan_key") != plan_key:
        raise RuntimeError("existing preparation plan differs")
    required_files = (
        "PREPARED-MANIFEST.sha256",
        "generated/environment/spack.yaml",
        "generated/environment/spack.lock",
        "source-mirror.sha256",
        "bootstrap-mirror.sha256",
        "source-mirror-links.sha256",
        "bootstrap-mirror-links.sha256",
        "identity/source-archive.tar.gz",
        "cases/CASES.json",
        "cases/run-one.sh",
    )
    for relative in required_files:
        if not (preparation / relative).is_file():
            raise RuntimeError("required preparation file missing: {0}".format(relative))
    for relative in ("spack-unpack", "packages-unpack", "spack-cache", "bootstrap-mirror", "source-mirror"):
        if not (preparation / relative).is_dir():
            raise RuntimeError("required preparation directory missing: {0}".format(relative))
    verify_manifest(preparation / "PREPARED-MANIFEST.sha256")
    verify_links(preparation / "source-mirror", preparation / "source-mirror-links.sha256")
    verify_links(preparation / "bootstrap-mirror", preparation / "bootstrap-mirror-links.sha256")
    if sha256(preparation / "identity/source-archive.tar.gz") != receipt["source_archive_sha256"]:
        raise RuntimeError("source archive identity differs")
    python = Path(receipt["python"])
    if not python.is_file() or sha256(python) != receipt["python_sha256"]:
        raise RuntimeError("prepared Python interpreter identity differs")
    owner_path = Path(receipt["version_root"]) / "OWNER.json"
    owner = json.loads(owner_path.read_text())
    if owner.get("plan_key") != receipt["plan_key"] or owner.get("preparation") != str(preparation):
        raise RuntimeError("version owner identity differs")
    if sha256(owner_path) != receipt["owner_sha256"]:
        raise RuntimeError("version owner receipt changed")
    return receipt


def verify_mirrors(configuration, expected_url):
    mirrors = json.loads(configuration.read_text())
    expected = {"mirrors": {"source-cache": expected_url}}
    if mirrors != expected:
        raise RuntimeError("effective Spack mirrors are not the prepared local source mirror")


def verify_build(preparation):
    return verify_built_artifacts(preparation, True)


def verify_built_artifacts(preparation, require_complete=False):
    prepared = verify_prepared(preparation)
    version = Path(prepared["version_root"])
    receipt_path = version / "BUILD-RECEIPT.json"
    manifest_path = version / "INSTALL-MANIFEST.sha256"
    complete_path = version / "BUILD-COMPLETE.sha256"
    links_path = version / "INSTALL-LINKS.sha256"
    required = (
        receipt_path,
        manifest_path,
        links_path,
        version / "run-env.sh",
        version / "ldd.txt",
    )
    if require_complete:
        required += (complete_path,)
    for path in required:
        if not path.is_file():
            raise RuntimeError("build artifact missing: {0}".format(path))
    verify_manifest(manifest_path)
    if require_complete:
        complete = complete_path.read_text().split()
        if len(complete) != 2 or sha256(receipt_path) != complete[0]:
            raise RuntimeError("build completion receipt mismatch")
    receipt = json.loads(receipt_path.read_text())
    store = Path(receipt["install_store"])
    if store != version / "store" or not store.is_dir():
        raise RuntimeError("installed store identity differs")
    verify_links(store, links_path)
    manifest_files = {
        line.split("  ", 1)[1] for line in manifest_path.read_text().splitlines()
    }
    actual_files = {
        str(path) for path in store.rglob("*") if path.is_file() and not path.is_symlink()
    }
    if actual_files != manifest_files:
        raise RuntimeError("installed store regular-file set differs from manifest")
    binary = Path(receipt["palace_binary"])
    if not binary.is_file() or sha256(binary) != receipt["palace_binary_sha256"]:
        raise RuntimeError("Palace executable identity differs")
    jit = Path(receipt["libceed_jit_source"])
    if not jit.is_dir() or not any(jit.rglob("*")):
        raise RuntimeError("libCEED JIT source is missing")
    for line in (version / "ldd.txt").read_text().splitlines():
        words = line.replace("=>", " ").split()
        paths = [word for word in words if word.startswith("/")]
        if paths:
            library = str(Path(paths[0]).resolve())
            if library.startswith(str(store) + os.sep) and library not in manifest_files:
                raise RuntimeError("owned runtime library is absent from install manifest: {0}".format(library))
    return receipt


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    prepared = sub.add_parser("prepared")
    prepared.add_argument("preparation", type=Path)
    prepared.add_argument("--plan-key")
    build = sub.add_parser("build")
    build.add_argument("preparation", type=Path)
    artifacts = sub.add_parser("artifacts")
    artifacts.add_argument("preparation", type=Path)
    mirrors = sub.add_parser("mirrors")
    mirrors.add_argument("configuration", type=Path)
    mirrors.add_argument("expected_url")
    args = parser.parse_args()
    if args.command is None:
        parser.error("a verification command is required")
    if args.command == "prepared":
        verify_prepared(args.preparation.resolve(), args.plan_key)
    elif args.command == "build":
        verify_build(args.preparation.resolve())
    elif args.command == "mirrors":
        verify_mirrors(args.configuration.resolve(), args.expected_url)
    else:
        verify_built_artifacts(args.preparation.resolve())


if __name__ == "__main__":
    main()
