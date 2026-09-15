#!/usr/bin/env bash
#SBATCH --job-name=palace-spack-validate
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

: "${SLURM_JOB_ID:?submit this script with sbatch}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
[[ $SLURM_NTASKS == 1 && $SLURM_CPUS_PER_TASK =~ ^[1-9][0-9]*$ ]] || { echo "validation requires one task and positive cpus-per-task" >&2; exit 2; }
: "${PREPARATION:?set PREPARATION to an absolute prepared directory}"
[[ $PREPARATION == /* ]] || { echo "PREPARATION must be absolute" >&2; exit 2; }
[[ $PREPARATION =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported PREPARATION path characters" >&2; exit 2; }
verify="$PREPARATION/source/palace/scripts/spack-cpu/verify.py"
python=$(awk -F'"' '$2 == "python" {print $4}' "$PREPARATION/PREPARED.json")
[[ $python == /* && -x $python ]] || { echo "prepared Python interpreter missing" >&2; exit 1; }
"$python" "$verify" build "$PREPARATION"
version=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version_root"])' "$PREPARATION/PREPARED.json")
build_receipt="$version/BUILD-RECEIPT.json"
recorded_binary=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["palace_binary"])' "$build_receipt")
source "$version/run-env.sh"
[[ -x $PALACE_BIN && -x $PALACE_MPIRUN && -d $CEED_JIT_SOURCE_ROOT ]]
[[ $PALACE_BIN == "$recorded_binary" ]] || { echo "runtime Palace executable differs from build receipt" >&2; exit 1; }
"$python" "$verify" elf "$PALACE_BIN"
log_dir="$PREPARATION/validation-logs/$SLURM_JOB_ID"
[[ ! -e $log_dir ]] || { echo "validation log directory already exists" >&2; exit 1; }
mkdir -p "$log_dir"
ldd "$PALACE_BIN" > "$log_dir/ldd.txt"
! grep -q 'not found' "$log_dir/ldd.txt" || { echo "unresolved shared library" >&2; exit 1; }
"$PALACE_BIN" --help
sha256sum "$PALACE_BIN" "$PALACE_MPIRUN"
echo "Non-solving startup validation complete. JIT execution, numerical results, and F1 validation remain pending."
