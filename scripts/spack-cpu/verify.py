#!/usr/bin/env python3
"""Verify immutable preparation and installation receipts."""

import argparse
import hashlib
import importlib
import json
import os
import platform
import sys
import sysconfig
from pathlib import Path


sys.dont_write_bytecode = True
MINIMUM_PYTHON = (3, 8)
REQUIRED_PYTHON_MODULES = ("ssl", "sqlite3", "ctypes", "hashlib", "json")
PYTHON_COMPATIBILITY_KEYS = (
    "implementation",
    "major_minor",
    "soabi",
    "ext_suffix",
    "machine",
    "exec_prefix",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_linux_x86_64_elf(path):
    path = Path(path)
    if platform.system() != "Linux":
        raise RuntimeError("Palace executable verification requires Linux")
    if path.is_symlink() or not path.is_file() or not os.access(str(path), os.X_OK):
        raise RuntimeError("Palace executable must be an executable regular file")
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise RuntimeError("Palace executable is not an ELF file")
    elf_type = int.from_bytes(header[16:18], "little")
    if (header[4] != 2 or header[5] != 1 or elf_type not in (2, 3) or
            int.from_bytes(header[18:20], "little") != 62):
        raise RuntimeError("Palace executable is not a little-endian x86-64 ELF")
    return path


def current_python_identity():
    if sys.implementation.name != "cpython":
        raise RuntimeError("CPython is required")
    if sys.version_info[:2] < MINIMUM_PYTHON:
        raise RuntimeError("Python 3.8 or newer is required")
    modules = []
    for name in REQUIRED_PYTHON_MODULES:
        importlib.import_module(name)
        modules.append(name)
    executable = Path(sys.executable).resolve()
    identity = {
        "implementation": sys.implementation.name,
        "version": ".".join(str(value) for value in sys.version_info[:3]),
        "major_minor": list(sys.version_info[:2]),
        "soabi": sysconfig.get_config_var("SOABI"),
        "ext_suffix": sysconfig.get_config_var("EXT_SUFFIX"),
        "machine": platform.machine(),
        "exec_prefix": str(Path(sys.exec_prefix).resolve()),
        "executable": str(executable),
        "executable_sha256": sha256(executable),
        "required_imports": modules,
    }
    if not identity["soabi"] or not identity["ext_suffix"]:
        raise RuntimeError("Python SOABI and extension suffix are required")
    return identity


def python_compatibility(identity):
    return {key: identity[key] for key in PYTHON_COMPATIBILITY_KEYS}


def verify_python_compatibility(expected, current=None):
    current = current or current_python_identity()
    if current["implementation"] != "cpython":
        raise RuntimeError("CPython is required")
    if tuple(current["major_minor"]) < MINIMUM_PYTHON:
        raise RuntimeError("Python 3.8 or newer is required")
    if current["required_imports"] != list(REQUIRED_PYTHON_MODULES):
        raise RuntimeError("required Python standard-library imports differ")
    for key in PYTHON_COMPATIBILITY_KEYS:
        if current.get(key) != expected.get(key):
            raise RuntimeError("prepared Python compatibility differs: {0}".format(key))
    return current


def _manifest_entries(path):
    entries = {}
    for line in path.read_text().splitlines():
        expected, name = line.split("  ", 1)
        if name in entries:
            raise RuntimeError("duplicate manifest path: {0}".format(name))
        entries[name] = expected
    return entries


def verify_clingo_import(preparation, identity, manifest_path=None):
    manifest_path = manifest_path or preparation / "PREPARED-MANIFEST.sha256"
    pattern = "clingo{0}".format(identity["ext_suffix"])
    candidates = [
        path
        for path in (preparation / "spack-cache" / "bootstrap" / "store").rglob(pattern)
        if "site-packages" in path.parts and path.is_file()
    ]
    if len(candidates) != 1:
        raise RuntimeError("expected one prepared clingo extension, found {0}".format(len(candidates)))
    extension = candidates[0]
    entries = _manifest_entries(manifest_path)
    expected_sha = entries.get(str(extension))
    if expected_sha is None or sha256(extension) != expected_sha:
        raise RuntimeError("prepared clingo extension is not manifest-bound")

    site_packages = extension.parent
    previous_path = list(sys.path)
    try:
        sys.path.insert(0, str(site_packages))
        importlib.invalidate_caches()
        module = importlib.import_module("clingo")
        if Path(module.__file__).resolve() != extension.resolve():
            raise RuntimeError("clingo imported from outside the prepared bootstrap store")
        module.Control()
    finally:
        sys.path[:] = previous_path
    return {"path": str(extension), "sha256": expected_sha}


def verify_manifest(path):
    for name, expected in _manifest_entries(path).items():
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


def verify_preparation_cache_config(preparation, receipt):
    bootstrap_root = preparation / "spack-cache" / "bootstrap"
    if receipt.get("bootstrap_root") != str(bootstrap_root):
        raise RuntimeError("prepared bootstrap root identity differs")
    bootstrap_lines = (preparation / "spack-config" / "bootstrap.yaml").read_text().splitlines()
    configured = []
    for line in bootstrap_lines:
        match = line.strip().split(":", 1)
        if len(match) == 2 and match[0] == "root":
            configured.append(match[1].strip().strip("'\""))
    if configured != [str(bootstrap_root)]:
        raise RuntimeError("prepared bootstrap root configuration differs")
    source_cache = (preparation / "spack-config" / "config.yaml").read_text()
    expected = "config:\n  source_cache: '$user_cache_path/source'\n"
    if source_cache != expected:
        raise RuntimeError("prepared writable source-cache configuration differs")


def verify_prepared(preparation, plan_key=None):
    receipt_path = preparation / "PREPARED.json"
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("schema") != 2:
        raise RuntimeError("preparation schema is obsolete; create a new preparation with the current scripts")
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
        "spack-config/bootstrap.yaml",
        "spack-config/config.yaml",
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
    verify_preparation_cache_config(preparation, receipt)
    current = verify_python_compatibility(receipt["python_compatibility"])
    python = Path(receipt["python"]).resolve()
    if not python.is_file() or Path(current["executable"]) != python:
        raise RuntimeError("the running Python interpreter path differs from preparation")
    verify_clingo_import(preparation, current)
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
    if receipt.get("schema") != 2:
        raise RuntimeError("build receipt schema differs")
    if receipt.get("preparation") != str(preparation):
        raise RuntimeError("build receipt preparation path differs")
    if receipt.get("prepared_receipt_sha256") != sha256(preparation / "PREPARED.json"):
        raise RuntimeError("build receipt preparation identity differs")
    if receipt.get("prepared_plan_key") != prepared["plan_key"]:
        raise RuntimeError("build receipt plan identity differs")
    if receipt.get("prepared_python_compatibility") != prepared["python_compatibility"]:
        raise RuntimeError("build receipt prepared Python compatibility differs")
    verify_python_compatibility(prepared["python_compatibility"], receipt["build_python"])
    python_log = Path(receipt["build_python_log"])
    if not python_log.is_file() or sha256(python_log) != receipt["build_python_log_sha256"]:
        raise RuntimeError("build Python log identity differs")
    if json.loads(python_log.read_text()) != receipt["build_python"]:
        raise RuntimeError("build Python receipt differs from its early log")
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
    prefix = Path(receipt["palace_prefix"])
    binary = Path(receipt["palace_binary"])
    if prefix != prefix.resolve():
        raise RuntimeError("Palace installed prefix is not canonical")
    if binary != binary.resolve():
        raise RuntimeError("Palace executable receipt path is not canonical")
    expected_binary_path = prefix / "bin" / "palace-x86_64.bin"
    verify_linux_x86_64_elf(expected_binary_path)
    expected_binary = expected_binary_path.resolve()
    if binary != expected_binary:
        raise RuntimeError("Palace receipt does not name the direct installed ELF")
    resolved_prefix = prefix.resolve()
    if os.path.commonpath((str(resolved_prefix), str(binary))) != str(resolved_prefix):
        raise RuntimeError("Palace executable resolves outside its installed prefix")
    if sha256(binary) != receipt["palace_binary_sha256"]:
        raise RuntimeError("Palace executable identity differs")
    ldd_path = version / "ldd.txt"
    if receipt.get("ldd_sha256") != sha256(ldd_path):
        raise RuntimeError("Palace ldd receipt identity differs")
    if any("not found" in line for line in ldd_path.read_text().splitlines()):
        raise RuntimeError("Palace ldd receipt has an unresolved shared library")
    job_cache = Path(receipt["spack_user_cache_path"])
    expected_cache = version / "spack-cache" / receipt["slurm_job_id"]
    if job_cache != expected_cache or not job_cache.is_dir():
        raise RuntimeError("build writable cache identity differs")
    if receipt.get("source_cache") != str(job_cache / "source"):
        raise RuntimeError("build source-cache identity differs")
    if receipt.get("bootstrap_root") != prepared["bootstrap_root"]:
        raise RuntimeError("build bootstrap root identity differs")
    jit = Path(receipt["libceed_jit_source"])
    if not jit.is_dir() or not any(jit.rglob("*")):
        raise RuntimeError("libCEED JIT source is missing")
    for line in ldd_path.read_text().splitlines():
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
    elf = sub.add_parser("elf")
    elf.add_argument("path", type=Path)
    sub.add_parser("python-identity")
    args = parser.parse_args()
    if args.command is None:
        parser.error("a verification command is required")
    if args.command == "python-identity":
        print(json.dumps(current_python_identity(), sort_keys=True))
    elif args.command == "prepared":
        verify_prepared(args.preparation.resolve(), args.plan_key)
    elif args.command == "build":
        verify_build(args.preparation.resolve())
    elif args.command == "mirrors":
        verify_mirrors(args.configuration.resolve(), args.expected_url)
    elif args.command == "elf":
        verify_linux_x86_64_elf(args.path)
    else:
        verify_built_artifacts(args.preparation.resolve())


if __name__ == "__main__":
    main()
