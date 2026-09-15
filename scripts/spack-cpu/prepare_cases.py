#!/usr/bin/env python3
"""Prepare immutable public smoke inputs and owner-provided Xmon comparisons."""

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
    parser.add_argument("--xmon-archive", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    args = parser.parse_args()
    if args.destination.exists():
        raise RuntimeError("case destination already exists")
    if sha256(args.xmon_archive) != ARCHIVE_SHA:
        raise RuntimeError("Xmon archive checksum mismatch")
    args.destination.mkdir(parents=True)

    smoke = args.destination / "public-cavity2d"
    shutil.copytree(args.source / "examples/cavity2d", smoke)
    smoke_cases = [
        ("cavity2d-eigenmode", "cavity2d.json"),
        ("cavity2d-electrostatic", "cavity2d_electrostatic.json"),
        ("cavity2d-driven", "cavity2d_driven.json"),
        ("cavity2d-transient", "cavity2d_transient.json"),
    ]

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
    derived = []
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
    manifest = {
        "schema": 1,
        "state": "PREPARED_NOT_RUN",
        "semantic_state": "CONVERGING",
        "cases": cases,
        "notes": [
            "Original Xmon bytes are unchanged.",
            "Each derived Xmon config changes exactly one JSON pointer from the original.",
            "Resolved solver backends and numerical results require an authorized later run.",
        ],
    }
    (args.destination / "CASES.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    harness = '''#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
: "${SLURM_JOB_ID:?run inside an authorized Slurm allocation}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
[[ $# == 3 ]] || { echo "Usage: $0 CASES.json CASE_ID RUN_ROOT" >&2; exit 2; }
manifest=$1
case_id=$2
run_root=$3
[[ $run_root == /* ]] || { echo "RUN_ROOT must be absolute" >&2; exit 2; }
python=@PALACE_PYTHON@
[[ -x $python ]] || { echo "prepared Python interpreter missing: $python" >&2; exit 1; }
readarray -t selected < <("$python" - "$manifest" "$case_id" <<'PYS'
import json, sys
items = [x for x in json.load(open(sys.argv[1]))["cases"] if x["id"] == sys.argv[2]]
if len(items) != 1:
    raise SystemExit("case id not found or duplicate")
print(items[0]["directory"])
print(items[0]["config"])
for name, digest in sorted(items[0]["files"].items()):
    if name.startswith("/") or ".." in name.split("/"):
        raise SystemExit("unsafe case input path")
    print(digest + "  " + name)
PYS
)
base=$(cd -- "$(dirname -- "$manifest")" && pwd -P)
[[ $(realpath "$manifest") == "$base/CASES.json" ]] || { echo "manifest must be the canonical prepared CASES.json" >&2; exit 1; }
preparation=$(realpath "$base/..")
verify=$preparation/source/palace/scripts/spack-cpu/verify.py
[[ -f $verify ]] || { echo "prepared verifier missing" >&2; exit 1; }
"$python" "$verify" build "$preparation"
version=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version_root"])' "$preparation/PREPARED.json")
build_receipt=$version/BUILD-RECEIPT.json
build_receipt_sha=$(sha256sum "$build_receipt" | awk '{print $1}')
binary_sha=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["palace_binary_sha256"])' "$build_receipt")
binary_path=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["palace_binary"])' "$build_receipt")
run_env=$version/run-env.sh
[[ -f $run_env ]] || { echo "prepared build runtime activation missing" >&2; exit 1; }
source_dir=$base/${selected[0]}
config=${selected[1]}
[[ -f $source_dir/$config ]] || { echo "case configuration missing" >&2; exit 1; }
for entry in "${selected[@]:2}"; do
  expected=${entry%%  *}
  relative=${entry#*  }
  [[ -f $source_dir/$relative && ! -L $source_dir/$relative ]] || { echo "case input missing or not regular: $relative" >&2; exit 1; }
  [[ $(sha256sum "$source_dir/$relative" | awk '{print $1}') == "$expected" ]] || { echo "case input checksum mismatch: $relative" >&2; exit 1; }
done
run_dir=$run_root/${SLURM_JOB_ID}-${case_id}
[[ ! -e $run_dir ]] || { echo "run directory exists: $run_dir" >&2; exit 1; }
mkdir -p "$run_dir"
cp -a "$source_dir/." "$run_dir/"
source "$run_env"
[[ $PALACE_BIN == "$binary_path" ]] || { echo "runtime Palace executable differs from build receipt" >&2; exit 1; }
"$python" "$verify" elf "$PALACE_BIN"
while IFS= read -r name; do
  [[ $name =~ ^(OMPI_MCA_|PMIX_MCA_|PRTE_MCA_) ]] && unset "$name"
done < <(compgen -e)
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK OPENBLAS_NUM_THREADS=1
export OMP_PROC_BIND=close OMP_PLACES=cores
for entry in "${selected[@]:2}"; do
  relative=${entry#*  }
  sha256sum "$run_dir/$relative"
done > "$run_dir/run-inputs.sha256"
{
  printf 'PALACE_BIN=%s\nPALACE_MPIRUN=%s\nCEED_JIT_SOURCE_ROOT=%s\n' "$PALACE_BIN" "$PALACE_MPIRUN" "$CEED_JIT_SOURCE_ROOT"
  printf 'OMP_NUM_THREADS=%s\nOPENBLAS_NUM_THREADS=%s\nOMP_PROC_BIND=%s\nOMP_PLACES=%s\n' "$OMP_NUM_THREADS" "$OPENBLAS_NUM_THREADS" "$OMP_PROC_BIND" "$OMP_PLACES"
  env | LC_ALL=C sort | grep -E '^(OMPI_MCA_|PMIX_MCA_|PRTE_MCA_)' || true
} > "$run_dir/runtime-env.txt"
config=$run_dir/$config
cd "$run_dir"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
"$PALACE_MPIRUN" -np "$SLURM_NTASKS" --bind-to core --map-by "slot:PE=$SLURM_CPUS_PER_TASK" --nooversubscribe "$PALACE_BIN" "$config" > solver.stdout 2> solver.stderr
status=$?
set -e
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"$python" - "$run_dir/EXECUTION-RECEIPT.json.tmp" "$case_id" "$config" "$SLURM_JOB_ID" "$SLURM_NTASKS" "$SLURM_CPUS_PER_TASK" "$started" "$finished" "$status" "$build_receipt_sha" "$binary_sha" "$PALACE_BIN" "$PALACE_MPIRUN" <<'PYS'
import hashlib, json, sys
from pathlib import Path
out, case_id, config, job, ranks, threads, started, finished, status, build_sha, binary_sha, binary, mpirun = sys.argv[1:]
document = json.load(open(config))
solver = document.get("Solver", {})
def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
record = {
    "schema": 1,
    "process_state": "PROCESS_COMPLETE" if int(status) == 0 else "PROCESS_FAILED",
    "semantic_state": "CONVERGING",
    "scientific_acceptance": None,
    "case_id": case_id,
    "config": config,
    "config_sha256": digest(config),
    "run_inputs_manifest_sha256": digest("run-inputs.sha256"),
    "build_receipt_sha256": build_sha,
    "palace_binary": binary,
    "palace_binary_sha256": binary_sha,
    "mpirun": mpirun,
    "slurm_job_id": job,
    "mpi_ranks": int(ranks),
    "omp_threads_per_rank": int(threads),
    "started_utc": started,
    "finished_utc": finished,
    "exit_status": int(status),
    "output_directory": str(Path.cwd()),
    "solver_types": {
        "eigenmode_requested": solver.get("Eigenmode", {}).get("Type", "Default"),
        "eigenmode_resolved": ("SLEPc" if solver.get("Eigenmode", {}).get("Type", "Default") == "Default" else solver.get("Eigenmode", {}).get("Type")),
        "linear_requested": solver.get("Linear", {}).get("Type", "Default"),
        "linear_resolved": ("SuperLU" if solver.get("Linear", {}).get("Type", "Default") == "Default" else solver.get("Linear", {}).get("Type")),
    },
    "stdout_sha256": digest("solver.stdout"),
    "stderr_sha256": digest("solver.stderr"),
}
Path(out).write_text(json.dumps(record, indent=2, sort_keys=True) + "\\n")
PYS
mv "$run_dir/EXECUTION-RECEIPT.json.tmp" "$run_dir/EXECUTION-RECEIPT.json"
exit "$status"
'''
    run_one = args.destination / "run-one.sh"
    run_one.write_text(harness.replace("@PALACE_PYTHON@", shlex.quote(str(args.python.resolve()))))
    run_one.chmod(0o755)


if __name__ == "__main__":
    main()
