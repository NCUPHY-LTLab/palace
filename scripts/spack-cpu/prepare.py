#!/usr/bin/env python3
"""Small deterministic helpers for Palace CPU preparation."""

import argparse
import hashlib
import json
import os
import re
from pathlib import Path


def fields(values):
    result = {}
    for key, value in values or []:
        if key in result:
            raise RuntimeError("duplicate field: {0}".format(key))
        result[key] = value
    return result


def plan_key(args):
    payload = fields(args.field)
    print(hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest())


def lock_rows(args):
    lock = json.loads(args.lock.read_text())
    items = [lock["spack"], lock["packages"]] + lock["snapshots"]
    for item in items:
        name = item.get("archive", item.get("package", "spack") + "-" + item.get("commit", "") + ".tar.gz")
        print("\t".join((name, item["url"], item["sha256"])))


def patch_rows(args):
    for item in json.loads(args.lock.read_text())["package_patches"]:
        print(item["file"] + "\t" + item["sha256"])


def validate_concrete(args):
    lock = json.loads(args.lock.read_text())
    expected_version = args.slurm_spec.split("@=", 1)[1]
    matches = [x for x in lock["concrete_specs"].values() if x.get("name") == "slurm"]
    if len(matches) != 1 or matches[0].get("version") != expected_version:
        raise RuntimeError("concrete lock has wrong Slurm version")
    if matches[0].get("external", {}).get("path") != str(args.slurm_prefix):
        raise RuntimeError("concrete lock did not retain external Slurm prefix")
    gcc = [x for x in lock["concrete_specs"].values()
           if x.get("name") == "gcc" and x.get("version") == args.gcc_version and "external" in x]
    if len(gcc) != 1 or gcc[0]["external"].get("path") != str(args.gcc_prefix):
        raise RuntimeError("concrete lock did not retain the exact external seed GCC")


def prepared_fields(args):
    record = json.loads(args.receipt.read_text())
    for value in (
        record["site"], record["preparation_revision"], record["environment"],
        record["version_root"], record["plan_key"],
        json.dumps(record["python_compatibility"], sort_keys=True, separators=(",", ":")),
    ):
        print(value)


def write_record(args):
    record = fields(args.field)
    if args.kind == "owner":
        record = dict(record, schema=1)
    else:
        identity = json.loads(record.pop("python_identity"))
        record.update({
            "schema": 2,
            "state": "PREPARED",
            "semantic_state": "CONVERGING",
            "case_archive_sha256": (record["case_identity"]
                                    if record["case_mode"] != "public-only" else None),
            "python_compatibility": {
                key: identity[key]
                for key in ("implementation", "major_minor", "soabi", "ext_suffix", "machine", "exec_prefix")
            },
        })
    args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")


def write_build_record(args):
    record = fields(args.field)
    record.update({
        "schema": 2,
        "state": "BUILD_COMPLETE",
        "semantic_state": "CONVERGING",
        "openmp_num_threads": 1,
        "openblas_num_threads": 1,
        "omp_proc_bind": "close",
        "omp_places": "cores",
    })
    for key in ("prepared_python_compatibility", "build_python"):
        record[key] = json.loads(record[key])
    args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_staged(args):
    for line in args.manifest.read_text().splitlines():
        expected, name = line.split("  ", 1)
        path = Path(name)
        if not path.is_file() or sha256(path) != expected:
            raise RuntimeError("staged install manifest mismatch: {0}".format(name))
    actual = []
    for path in sorted(args.root.rglob("*"), key=lambda item: str(item)):
        if path.is_symlink():
            actual.append("{0} -> {1}\n".format(path, os.readlink(str(path))))
    expected = args.links.read_text().split()[0]
    if hashlib.sha256("".join(actual).encode()).hexdigest() != expected:
        raise RuntimeError("staged install symlink manifest mismatch")


def render(template, target, replacements):
    if target.is_symlink():
        raise RuntimeError("job path may not be a symbolic link: {0}".format(target))
    if target.exists():
        if not target.is_file():
            raise RuntimeError("job path exists and is not a file: {0}".format(target))
        return False
    text = template.read_text()
    for key, value in replacements.items():
        text = text.replace("@{0}@".format(key), value)
    if re.search(r"@[A-Z_]+@", text):
        raise RuntimeError("unresolved job template token in {0}".format(template))
    with target.open("x") as stream:
        stream.write(text)
    target.chmod(0o755)
    return True


def generate_jobs(args):
    job_dir = args.root / "jobs" / args.preparation.name
    log_dir = job_dir / "logs"
    validation_root = job_dir / "validation"
    if job_dir.exists() and (not job_dir.is_dir() or job_dir.is_symlink()):
        raise RuntimeError("job path is not an owned directory: {0}".format(job_dir))
    log_dir.mkdir(parents=True, exist_ok=True)
    validation_root.mkdir(exist_ok=True)
    for directory in (log_dir, validation_root):
        if directory.is_symlink():
            raise RuntimeError("job subdirectory may not be a symbolic link: {0}".format(directory))
    partition = "ct112" if args.site == "f1" else "EDIT_PARTITION"
    common = {
        "ACCOUNT": "EDIT_ACCOUNT",
        "PARTITION": partition,
        "PREPARATION": str(args.preparation),
        "LOG_DIR": str(log_dir),
        "VALIDATION_ROOT": str(validation_root),
        "BUILD_CPUS": "8",
        "BUILD_TIME": "08:00:00",
        "VALIDATE_RANKS": "4",
        "VALIDATE_THREADS": "1",
        "VALIDATE_TIME": "01:00:00",
    }
    render(args.templates / "build.sbatch.in", job_dir / "build.sbatch", common)
    render(args.templates / "validate.sbatch.in", job_dir / "validate.sbatch", common)
    print("jobs: {0}".format(job_dir))
    print("edit and submit: {0}".format(job_dir / "build.sbatch"))
    print("after a successful build, edit and submit: {0}".format(job_dir / "validate.sbatch"))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    key = sub.add_parser("plan-key")
    key.add_argument("--field", nargs=2, action="append")
    rows = sub.add_parser("downloads")
    rows.add_argument("lock", type=Path)
    patches = sub.add_parser("patches")
    patches.add_argument("lock", type=Path)
    concrete = sub.add_parser("validate-concrete")
    concrete.add_argument("lock", type=Path)
    concrete.add_argument("slurm_spec")
    concrete.add_argument("slurm_prefix", type=Path)
    concrete.add_argument("gcc_version")
    concrete.add_argument("gcc_prefix", type=Path)
    prepared = sub.add_parser("prepared-fields")
    prepared.add_argument("receipt", type=Path)
    record = sub.add_parser("write-record")
    record.add_argument("kind", choices=("owner", "prepared"))
    record.add_argument("output", type=Path)
    record.add_argument("--field", nargs=2, action="append")
    build_record = sub.add_parser("write-build-record")
    build_record.add_argument("output", type=Path)
    build_record.add_argument("--field", nargs=2, action="append")
    staged = sub.add_parser("verify-staged")
    staged.add_argument("manifest", type=Path)
    staged.add_argument("links", type=Path)
    staged.add_argument("root", type=Path)
    jobs = sub.add_parser("jobs")
    jobs.add_argument("site", choices=("f1", "ltlab"))
    jobs.add_argument("root", type=Path)
    jobs.add_argument("preparation", type=Path)
    jobs.add_argument("templates", type=Path)
    args = parser.parse_args()
    if args.command == "plan-key":
        plan_key(args)
    elif args.command == "downloads":
        lock_rows(args)
    elif args.command == "patches":
        patch_rows(args)
    elif args.command == "validate-concrete":
        validate_concrete(args)
    elif args.command == "prepared-fields":
        prepared_fields(args)
    elif args.command == "write-record":
        write_record(args)
    elif args.command == "write-build-record":
        write_build_record(args)
    elif args.command == "verify-staged":
        verify_staged(args)
    elif args.command == "jobs":
        generate_jobs(args)
    else:
        parser.error("a command is required")


if __name__ == "__main__":
    main()
