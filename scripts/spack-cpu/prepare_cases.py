#!/usr/bin/env python3
"""Prepare immutable public smoke inputs and optional owner-provided Xmon comparisons."""

import argparse
import hashlib
import json
import shlex
import shutil
import stat
import tarfile
from pathlib import Path, PurePosixPath

ARCHIVE_SHA = "c73772d1e8f739c3f174eecffb4a2b8bc5df7b2c622aa7302d4ea3adc09cdff6"
CONFIG_SHA = "7bd0e7dc97854c8bac7829dd71e16f2c8c91cfe3caec456d24455f8d68caeed2"
MESH_SHA = "942365447b123cebe2f1f3f70c7284b5bc284602d8ed137f968637a703177cf5"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def archive_member(bundle, suffix):
    matches = [m for m in bundle.getmembers() if PurePosixPath(m.name).name == suffix]
    if len(matches) != 1 or not matches[0].isfile():
        raise RuntimeError("expected one regular {0} in case archive".format(suffix))
    return matches[0]


def set_pointer(document, pointer, value):
    node = document
    parts = pointer.strip("/").split("/")
    for part in parts[:-1]:
        node = node[part]
    node[parts[-1]] = value


def file_manifest(directory):
    files = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("case input contains a symbolic link: {0}".format(path))
        if path.is_file():
            files[str(path.relative_to(directory))] = sha256(path)
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--xmon-archive", type=Path)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    args = parser.parse_args()
    if args.destination.exists():
        raise RuntimeError("case destination already exists")
    args.destination.mkdir(parents=True)

    smoke = args.destination / "public-cavity2d"
    shutil.copytree(args.source / "examples/cavity2d", smoke)
    smoke_cases = [
        ("cavity2d-eigenmode", "cavity2d.json"),
        ("cavity2d-electrostatic", "cavity2d_electrostatic.json"),
        ("cavity2d-driven", "cavity2d_driven.json"),
        ("cavity2d-transient", "cavity2d_transient.json"),
    ]

    derived = []
    original = None
    if args.xmon_archive is not None:
        if sha256(args.xmon_archive) != ARCHIVE_SHA:
            raise RuntimeError("Xmon archive checksum mismatch")
        xmon = args.destination / "xmon"
        xmon.mkdir()
        archive_copy = xmon / "owner-provided.tar.gz"
        shutil.copyfile(args.xmon_archive, archive_copy)
        archive_copy.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
        with tarfile.open(str(args.xmon_archive), "r:gz") as bundle:
            config_member = archive_member(bundle, "config.json")
            mesh_member = archive_member(bundle, "palace.msh")
            base_config = bundle.extractfile(config_member).read()
            mesh = bundle.extractfile(mesh_member).read()
        if hashlib.sha256(base_config).hexdigest() != CONFIG_SHA:
            raise RuntimeError("Xmon config checksum mismatch")
        if hashlib.sha256(mesh).hexdigest() != MESH_SHA:
            raise RuntimeError("Xmon mesh checksum mismatch")
        original = xmon / "original"
        original.mkdir()
        (original / "config.json").write_bytes(base_config)
        (original / "palace.msh").write_bytes(mesh)
        transforms = [
            ("eigen-slepc", "/Solver/Eigenmode/Type", "SLEPc"),
            ("eigen-arpack", "/Solver/Eigenmode/Type", "ARPACK"),
            ("linear-superlu", "/Solver/Linear/Type", "SuperLU"),
            ("linear-mumps", "/Solver/Linear/Type", "MUMPS"),
        ]
        for name, pointer, value in transforms:
            directory = xmon / name
            directory.mkdir()
            document = json.loads(base_config.decode("utf-8"))
            set_pointer(document, pointer, value)
            config = directory / "config.json"
            config.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
            (directory / "palace.msh").write_bytes(mesh)
            derived.append({
                "id": "xmon-" + name,
                "directory": str(directory.relative_to(args.destination)),
                "config": "config.json",
                "config_sha256": sha256(config),
                "base_config_sha256": CONFIG_SHA,
                "transform": {"pointer": pointer, "value": value},
                "files": file_manifest(directory),
            })

    cases = []
    for name, config in smoke_cases:
        path = smoke / config
        cases.append({
            "id": name,
            "directory": str(smoke.relative_to(args.destination)),
            "config": config,
            "config_sha256": sha256(path),
            "class": "public-small-smoke",
            "files": file_manifest(smoke),
        })
    if original is not None:
        cases.append({
            "id": "xmon-original",
            "directory": "xmon/original",
            "config": "config.json",
            "config_sha256": CONFIG_SHA,
            "mesh_sha256": MESH_SHA,
            "archive_sha256": ARCHIVE_SHA,
            "class": "owner-provided-original",
            "files": file_manifest(original),
        })
        cases.extend(derived)
    input_manifests = args.destination / "manifests"
    input_manifests.mkdir()
    for case in cases:
        relative = "manifests/{0}.sha256".format(case["id"])
        case["input_manifest"] = relative
        lines = ["{0}  {1}\n".format(digest, name)
                 for name, digest in sorted(case["files"].items())]
        (args.destination / relative).write_text("".join(lines))
    manifest = {
        "schema": 1,
        "state": "PREPARED_NOT_RUN",
        "semantic_state": "CONVERGING",
        "cases": cases,
        "case_mode": "xmon-c73772d" if original is not None else "public-only",
        "notes": ([
            "Original Xmon bytes are unchanged.",
            "Each derived Xmon config changes exactly one JSON pointer from the original.",
        ] if original is not None else []) + [
            "Resolved solver backends and numerical results require an authorized later run."
        ],
    }
    (args.destination / "CASES.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    harness = r'''#!/usr/bin/env bash
#SBATCH --job-name=palace-prepared-case
#SBATCH --signal=B:TERM@60
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
[[ $# == 3 ]] || { echo "Usage: $0 CASES.json CASE_ID RUN_ROOT" >&2; exit 2; }
manifest=$1
case_id=$2
export RUN_ROOT=$3
python=@PALACE_PYTHON@
[[ -x $python ]] || { echo "prepared Python interpreter missing: $python" >&2; exit 1; }
base=$(cd -- "$(dirname -- "$manifest")" && pwd -P)
[[ $(realpath "$manifest") == "$base/CASES.json" ]] || { echo "manifest must be the canonical prepared CASES.json" >&2; exit 1; }
readarray -t selected < <("$python" -B - "$manifest" "$case_id" <<'PYS'
import json, sys
items = [x for x in json.load(open(sys.argv[1]))["cases"] if x["id"] == sys.argv[2]]
if len(items) != 1:
    raise SystemExit("case id not found or duplicate")
print(items[0]["directory"])
print(items[0]["config"])
print(items[0]["input_manifest"])
PYS
)
export PREPARATION=$(realpath "$base/..")
export INPUT_DIR=$base/${selected[0]}
export CONFIG=${selected[1]}
export INPUT_MANIFEST=$base/${selected[2]}
export RUN_PACKAGE=$PREPARATION/source/palace/scripts/spack-cpu
exec "$RUN_PACKAGE/run-case.sbatch"
'''
    run_one = args.destination / "run-one.sh"
    run_one.write_text(harness.replace("@PALACE_PYTHON@", shlex.quote(str(args.python.resolve()))))
    run_one.chmod(0o755)


if __name__ == "__main__":
    main()
