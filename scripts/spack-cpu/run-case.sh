#!/usr/bin/env bash
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
unset PYTHONHOME PYTHONPATH

: "${SLURM_JOB_ID:?run inside an authorized Slurm allocation}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
: "${PREPARATION:?set PREPARATION to a completed preparation}"
: "${INPUT_DIR:?set INPUT_DIR to the sealed input directory}"
: "${INPUT_MANIFEST:?set INPUT_MANIFEST to its SHA-256 manifest}"
: "${CONFIG:?set CONFIG to its relative configuration path}"
: "${RUN_DIR:?set RUN_DIR to a new absolute output directory}"
: "${RUN_PACKAGE:?set RUN_PACKAGE to the reviewed run-case package snapshot}"
[[ $SLURM_NTASKS =~ ^[1-9][0-9]*$ && $SLURM_CPUS_PER_TASK =~ ^[1-9][0-9]*$ ]] || { echo "Slurm ranks and threads must be positive" >&2; exit 2; }
for path in "$PREPARATION" "$INPUT_DIR" "$INPUT_MANIFEST" "$RUN_DIR" "$RUN_PACKAGE"; do
  [[ $path == /* ]] || { echo "run paths must be absolute: $path" >&2; exit 2; }
done
[[ -d $INPUT_DIR && ! -L $INPUT_DIR && -f $INPUT_MANIFEST && ! -L $INPUT_MANIFEST ]] || { echo "input directory and manifest must be nonsymlink objects" >&2; exit 2; }
[[ ! -e $RUN_DIR ]] || { echo "RUN_DIR already exists: $RUN_DIR" >&2; exit 1; }
run_parent=$(dirname -- "$RUN_DIR")
[[ -d $run_parent && ! -L $run_parent ]] || { echo "RUN_DIR parent must be an existing nonsymlink directory" >&2; exit 2; }
run_dir=$RUN_DIR
[[ -d $RUN_PACKAGE && ! -L $RUN_PACKAGE ]] || { echo "RUN_PACKAGE must be a nonsymlink directory" >&2; exit 2; }
package=$(realpath "$RUN_PACKAGE")
helper=$package/run_case.py
canonical_script=$package/run-case.sh
[[ -f $helper && ! -L $helper && -f $canonical_script && ! -L $canonical_script ]] || { echo "reviewed run package is incomplete" >&2; exit 1; }
cmp -s "$canonical_script" "${BASH_SOURCE[0]}" || { echo "submitted script differs from RUN_PACKAGE authority" >&2; exit 1; }
expected_helper_sha=396985f36266e0f7c62e59e8721e9e39a51aef246f4a01abddc5a824817640ca
[[ $(sha256sum "$helper" | awk '{print $1}') == "$expected_helper_sha" ]] || { echo "run helper identity differs from submitted script" >&2; exit 1; }

# Use the preparation's recorded interpreter to run its frozen verifier. A system Python
# only reads this trusted receipt to locate that interpreter; it does not parse user input.
bootstrap_python=$(command -v python3)
python=$("$bootstrap_python" -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"])' "$PREPARATION/PREPARED.json")
[[ -x $python ]] || { echo "prepared Python interpreter is unavailable: $python" >&2; exit 1; }
verify=$PREPARATION/source/palace/scripts/spack-cpu/verify.py
[[ -f $verify ]] || { echo "frozen preparation verifier is unavailable" >&2; exit 1; }
"$python" -B "$verify" build "$PREPARATION"
version=$("$python" -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["version_root"])' "$PREPARATION/PREPARED.json")
export BUILD_RECEIPT=$version/BUILD-RECEIPT.json
run_env=$version/run-env.sh
export RUN_ENV=$run_env
[[ -f $BUILD_RECEIPT && -f $run_env ]] || { echo "completed runtime receipt or activation is missing" >&2; exit 1; }
source "$run_env"
export PALACE_BIN PALACE_MPIRUN
"$python" -B "$verify" elf "$PALACE_BIN"
receipt_binary=$("$python" -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["palace_binary"])' "$BUILD_RECEIPT")
[[ $PALACE_BIN == "$receipt_binary" ]] || { echo "runtime executable differs from build receipt" >&2; exit 1; }

mkdir "$run_dir"
export CONFIG RUN_STARTED_UTC=$(date -u +%FT%TZ)
phase=startup
signal_name=
child_pid=
finalized=0

write_receipt() {
  local state=$1 status=$2
  "$python" -B "$helper" receipt "$run_dir" "$phase" "$state" "$status" "${signal_name:-NONE}" "$(date -u +%FT%TZ)"
}
wait_for_child() {
  set +e
  while true; do
    wait "$child_pid"
    status=$?
    if [[ -n $signal_name && $status -ge 128 ]] && kill -0 "$child_pid" 2>/dev/null; then
      continue
    fi
    break
  done
  set -e
  child_pid=
}
apply_signal_status() {
  if [[ $signal_name == TERM ]]; then
    status=143
  elif [[ $signal_name == INT ]]; then
    status=130
  fi
}
on_signal() {
  [[ -n $signal_name ]] || signal_name=$1
  [[ $phase == *-signal ]] || phase=${phase}-signal
  finalized=0
  if [[ -n ${child_pid:-} ]]; then
    kill -s "$signal_name" "$child_pid" 2>/dev/null || true
    # Bash starts asynchronous commands with SIGINT ignored. Forward INT for
    # provenance, then use TERM to ensure the child is reaped; the outer
    # status and receipt still preserve the observed INT as 130.
    [[ $signal_name != INT ]] || kill -TERM "$child_pid" 2>/dev/null || true
  elif [[ $signal_name == TERM ]]; then
    exit 143
  else
    exit 130
  fi
}
on_exit() {
  local status=$?
  if [[ $finalized == 0 ]]; then
    set +e
    write_receipt PROCESS_FAILED "$status"
  fi
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap on_exit EXIT
write_receipt PROCESS_RUNNING 0

phase=staging
"$python" -B "$helper" stage "$INPUT_DIR" "$INPUT_MANIFEST" "$CONFIG" "$run_dir" > "$run_dir/.STAGING.json.tmp" &
child_pid=$!
wait_for_child
apply_signal_status
[[ $status == 0 ]] || exit "$status"
mv "$run_dir/.STAGING.json.tmp" "$run_dir/STAGING.json"
sha256sum "$canonical_script" "$helper" > "$run_dir/RUN-PACKAGE.sha256"

while IFS= read -r name; do
  [[ $name =~ ^(OMPI_MCA_|PMIX_MCA_|PRTE_MCA_) ]] && unset "$name"
done < <(compgen -e)
unset LD_PRELOAD
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK OPENBLAS_NUM_THREADS=1
export OMP_DYNAMIC=false OMP_PROC_BIND=close OMP_PLACES=cores
{
  printf 'PALACE_BIN=%s\nPALACE_MPIRUN=%s\nCEED_JIT_SOURCE_ROOT=%s\n' "$PALACE_BIN" "$PALACE_MPIRUN" "$CEED_JIT_SOURCE_ROOT"
  printf 'OMP_NUM_THREADS=%s\nOPENBLAS_NUM_THREADS=%s\nOMP_DYNAMIC=%s\nOMP_PROC_BIND=%s\nOMP_PLACES=%s\n' "$OMP_NUM_THREADS" "$OPENBLAS_NUM_THREADS" "$OMP_DYNAMIC" "$OMP_PROC_BIND" "$OMP_PLACES"
  printf 'SLURM_JOB_ID=%s\nSLURM_NTASKS=%s\nSLURM_CPUS_PER_TASK=%s\n' "$SLURM_JOB_ID" "$SLURM_NTASKS" "$SLURM_CPUS_PER_TASK"
} > "$run_dir/runtime-env.txt"
phase=native-dry-run
write_receipt PROCESS_RUNNING 0
(
  cd "$run_dir"
  exec "$PALACE_BIN" --dry-run "$CONFIG" > native-dry-run.stdout 2> native-dry-run.stderr
) &
child_pid=$!
wait_for_child
apply_signal_status
[[ $status == 0 ]] || exit "$status"
"$python" -B "$helper" resolved "$run_dir" "$run_dir/native-dry-run.stdout" "$run_dir/native-resolved.json"

phase=solve
write_receipt PROCESS_RUNNING 0
set +e
(
  cd "$run_dir"
  exec "$PALACE_MPIRUN" -np "$SLURM_NTASKS" \
    --bind-to core --map-by "slot:PE=$SLURM_CPUS_PER_TASK" --nooversubscribe \
    "$PALACE_BIN" "$CONFIG" > solver.stdout 2> solver.stderr
) &
child_pid=$!
wait_for_child
apply_signal_status
phase=process-complete
(
  cd "$run_dir"
  find . -type l -printf '%p -> %l\n' | LC_ALL=C sort > OUTPUT-LINKS.txt
  find . -type f ! -name OUTPUTS.sha256 ! -name PROCESS-RECEIPT.json ! -name PROCESS-RECEIPT.json.tmp -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum > OUTPUTS.sha256
)
if [[ $status == 0 ]]; then
  write_receipt PROCESS_COMPLETE "$status"
else
  phase=process-failed
  write_receipt PROCESS_FAILED "$status"
fi
finalized=1
exit "$status"
