#!/usr/bin/env python3
"""Validate, stage, and record one manifest-bound Palace run."""

import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path, PurePosixPath

RESERVED = {
    "OWNER-INPUTS.sha256", "OUTPUTS.sha256", "OUTPUT-LINKS.txt",
    "PROCESS-RECEIPT.json", "PROCESS-RECEIPT.json.tmp", "RUN-PACKAGE.sha256",
    "STAGING.json", ".STAGING.json.tmp", "runtime-env.txt", "native-dry-run.stdout",
    "native-dry-run.stderr", "native-resolved.json", "solver.stdout", "solver.stderr",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(value, label):
    if not isinstance(value, str) or not value or "\\" in value:
        raise RuntimeError("{0} must be a nonempty POSIX relative path".format(label))
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise RuntimeError("{0} must be a normalized contained relative path".format(label))
    return path


def read_manifest(path):
    entries = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if len(line) < 67 or line[64:66] not in ("  ", " *"):
            raise RuntimeError("invalid input manifest line {0}".format(number))
        digest = line[:64].lower()
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise RuntimeError("invalid input digest on line {0}".format(number))
        name = str(safe_relative(line[66:], "input manifest path"))
        if name in entries:
            raise RuntimeError("duplicate input manifest path: {0}".format(name))
        entries[name] = digest
    if not entries:
        raise RuntimeError("input manifest is empty")
    return entries


def stage(args):
    source = args.input_dir.resolve()
    manifest = args.manifest.resolve()
    destination = args.destination
    if not source.is_dir() or not manifest.is_file():
        raise RuntimeError("input directory or manifest is missing")
    existing = {path.name for path in destination.iterdir()} if destination.is_dir() else set()
    if not destination.is_dir() or existing - {"PROCESS-RECEIPT.json", ".STAGING.json.tmp"}:
        raise RuntimeError("run directory is missing or contains unexpected files")
    entries = read_manifest(manifest)
    for relative in entries:
        if PurePosixPath(relative).parts[0] in RESERVED:
            raise RuntimeError("input path collides with runner evidence: {0}".format(relative))
    config = str(safe_relative(args.config, "CONFIG"))
    if config not in entries:
        raise RuntimeError("CONFIG is absent from the input manifest")
    actual = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("input contains a symbolic link: {0}".format(path))
        if path.is_file():
            relative = str(path.relative_to(source))
            actual[relative] = sha256(path)
        elif not path.is_dir():
            raise RuntimeError("input contains a non-regular object: {0}".format(path))
    if actual != entries:
        raise RuntimeError("input regular-file set or checksum differs from manifest")
    for relative in sorted(entries):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(str(source / relative), str(target))
    copied = {}
    for path in sorted(destination.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("staged input contains a symbolic link: {0}".format(path))
        if path.is_file() and path.name not in ("PROCESS-RECEIPT.json", ".STAGING.json.tmp"):
            copied[str(path.relative_to(destination))] = sha256(path)
    if copied != entries:
        raise RuntimeError("copied input regular-file set or checksum differs")
    source_after = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("input gained a symbolic link during staging: {0}".format(path))
        if path.is_file():
            source_after[str(path.relative_to(source))] = sha256(path)
    if source_after != entries:
        raise RuntimeError("source input changed during staging")
    shutil.copyfile(str(manifest), str(destination / "OWNER-INPUTS.sha256"))
    return {"config": config, "input_manifest_sha256": sha256(manifest)}


def extract_resolved(text):
    marker = "Resolved configuration:\n"
    offset = text.find(marker)
    if offset < 0:
        raise RuntimeError("native dry-run did not emit a resolved configuration")
    payload = text[offset + len(marker):].lstrip()
    document, _ = json.JSONDecoder().raw_decode(payload)
    return document


def validate_resolved(args):
    run = args.run_dir.resolve()
    document = extract_resolved(args.dry_stdout.read_text(errors="strict"))
    model = document.get("Model", {})
    problem = document.get("Problem", {})
    manifest = read_manifest(run / "OWNER-INPUTS.sha256")
    for key in ("Mesh", "Partitioning"):
        value = model.get(key)
        if key == "Partitioning" and not value:
            continue
        relative = str(safe_relative(value, "Model/{0}".format(key)))
        if relative not in manifest or not (run / relative).is_file():
            raise RuntimeError("Model/{0} is not a manifest-bound regular input".format(key))
    output = str(safe_relative(problem.get("Output"), "Problem/Output"))
    if output in manifest or any(name.startswith(output + "/") for name in manifest):
        raise RuntimeError("Problem/Output overlaps immutable staged input")
    if PurePosixPath(output).parts[0] in RESERVED:
        raise RuntimeError("Problem/Output overlaps runner evidence")
    target = (run / output).resolve()
    if os.path.commonpath((str(run), str(target))) != str(run):
        raise RuntimeError("Problem/Output resolves outside the run directory")
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


def write_receipt(args):
    run = args.run_dir.resolve()
    resolved = run / "native-resolved.json"
    solver = json.loads(resolved.read_text()).get("Solver", {}) if resolved.is_file() else {}
    hashes = {}
    for name in ("OWNER-INPUTS.sha256", "RUN-PACKAGE.sha256", "native-dry-run.stdout",
                 "native-dry-run.stderr", "solver.stdout", "solver.stderr",
                 "OUTPUTS.sha256", "OUTPUT-LINKS.txt"):
        path = run / name
        if path.is_file():
            hashes[name] = sha256(path)
    record = {
        "schema": 1,
        "process_state": args.state,
        "phase": args.phase,
        "semantic_state": "CONVERGING",
        "scientific_acceptance": None,
        "exit_status": args.exit_status,
        "signal": args.signal,
        "slurm_job_id": os.environ["SLURM_JOB_ID"],
        "mpi_ranks": int(os.environ["SLURM_NTASKS"]),
        "omp_threads_per_rank": int(os.environ["SLURM_CPUS_PER_TASK"]),
        "preparation": os.environ["PREPARATION"],
        "prepared_receipt_sha256": sha256(Path(os.environ["PREPARATION"]) / "PREPARED.json"),
        "build_receipt_sha256": sha256(Path(os.environ["BUILD_RECEIPT"])),
        "run_env_sha256": sha256(Path(os.environ["RUN_ENV"])),
        "palace_binary": os.environ["PALACE_BIN"],
        "palace_binary_sha256": sha256(Path(os.environ["PALACE_BIN"])),
        "mpirun": os.environ["PALACE_MPIRUN"],
        "mpirun_sha256": sha256(Path(os.environ["PALACE_MPIRUN"])),
        "config": os.environ["CONFIG"],
        "run_directory": str(run),
        "started_utc": os.environ["RUN_STARTED_UTC"],
        "updated_utc": args.updated,
        "artifact_sha256": hashes,
        "solver_types": {
            "eigenmode": solver.get("Eigenmode", {}).get("Type"),
            "linear": solver.get("Linear", {}).get("Type"),
        },
    }
    temporary = run / "PROCESS-RECEIPT.json.tmp"
    temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    temporary.replace(run / "PROCESS-RECEIPT.json")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    stage_parser = sub.add_parser("stage")
    stage_parser.add_argument("input_dir", type=Path)
    stage_parser.add_argument("manifest", type=Path)
    stage_parser.add_argument("config")
    stage_parser.add_argument("destination", type=Path)
    resolved = sub.add_parser("resolved")
    resolved.add_argument("run_dir", type=Path)
    resolved.add_argument("dry_stdout", type=Path)
    resolved.add_argument("output", type=Path)
    receipt = sub.add_parser("receipt")
    receipt.add_argument("run_dir", type=Path)
    receipt.add_argument("phase")
    receipt.add_argument("state")
    receipt.add_argument("exit_status", type=int)
    receipt.add_argument("signal")
    receipt.add_argument("updated")
    args = parser.parse_args()
    if args.command == "stage":
        print(json.dumps(stage(args), sort_keys=True))
    elif args.command == "resolved":
        validate_resolved(args)
    elif args.command == "receipt":
        write_receipt(args)
    else:
        parser.error("a command is required")


if __name__ == "__main__":
    main()
