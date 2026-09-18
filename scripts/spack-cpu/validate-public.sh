#!/usr/bin/env bash
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
unset PYTHONHOME PYTHONPATH

: "${SLURM_JOB_ID:?run inside an authorized Slurm allocation}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
: "${PREPARATION:?set PREPARATION to the frozen preparation}"
: "${VALIDATION_DIR:?set VALIDATION_DIR to a new absolute output directory}"
[[ $SLURM_NTASKS =~ ^[1-9][0-9]*$ && $SLURM_CPUS_PER_TASK =~ ^[1-9][0-9]*$ ]] || {
  echo "Slurm ranks and threads must be positive" >&2
  exit 2
}
for path in "$PREPARATION" "$VALIDATION_DIR"; do
  [[ $path == /* ]] || { echo "validation paths must be absolute: $path" >&2; exit 2; }
done
[[ ! -e $VALIDATION_DIR ]] || { echo "validation directory already exists: $VALIDATION_DIR" >&2; exit 1; }
validation_parent=$(dirname -- "$VALIDATION_DIR")
[[ -d $validation_parent && ! -L $validation_parent ]] || {
  echo "validation parent must be an existing nonsymlink directory: $validation_parent" >&2
  exit 2
}

verify="$PREPARATION/source/palace/scripts/spack-cpu/verify.py"
python=$(awk -F'"' '$2 == "python" {print $4}' "$PREPARATION/PREPARED.json")
[[ -f $verify && $python == /* && -x $python ]] || { echo "frozen verifier or prepared Python is missing" >&2; exit 1; }
"$python" -B "$verify" build "$PREPARATION"
version=$("$python" -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["version_root"])' "$PREPARATION/PREPARED.json")
build_receipt=$version/BUILD-RECEIPT.json
run_env=$version/run-env.sh
source "$run_env"
[[ -x $PALACE_BIN && -x $PALACE_MPIRUN && -d $CEED_JIT_SOURCE_ROOT ]] || {
  echo "completed runtime activation is incomplete" >&2
  exit 1
}
recorded_binary=$("$python" -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["palace_binary"])' "$build_receipt")
[[ $PALACE_BIN == "$recorded_binary" ]] || { echo "runtime executable differs from build receipt" >&2; exit 1; }
"$python" -B "$verify" elf "$PALACE_BIN"

manifest=$PREPARATION/cases/CASES.json
runner=$PREPARATION/cases/run-one.sh
[[ -f $manifest && -x $runner ]] || { echo "prepared public cases are missing" >&2; exit 1; }
case_ids=(
  cavity2d-eigenmode
  cavity2d-electrostatic
  cavity2d-driven
  cavity2d-transient
)
states=(UNATTEMPTED UNATTEMPTED UNATTEMPTED UNATTEMPTED)
statuses=(- - - -)
run_dirs=(- - - -)

write_summary() {
  local tmp=$summary.tmp i
  {
    printf 'case\tstate\texit_status\trun_directory\n'
    for i in "${!case_ids[@]}"; do
      printf '%s\t%s\t%s\t%s\n' "${case_ids[$i]}" "${states[$i]}" "${statuses[$i]}" "${run_dirs[$i]}"
    done
  } > "$tmp"
  mv "$tmp" "$summary"
}

signal_name=
child_pid=
on_signal() {
  [[ -n $signal_name ]] || signal_name=$1
  if [[ -n ${child_pid:-} ]]; then
    kill -s "$signal_name" "$child_pid" 2>/dev/null || true
    [[ $signal_name != INT ]] || kill -TERM "$child_pid" 2>/dev/null || true
  elif [[ $signal_name == TERM ]]; then
    exit 143
  else
    exit 130
  fi
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
  if [[ $signal_name == TERM ]]; then
    status=143
  elif [[ $signal_name == INT ]]; then
    status=130
  fi
}
mkdir "$VALIDATION_DIR"
summary=$VALIDATION_DIR/summary.tsv
write_summary
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

ldd "$PALACE_BIN" > "$VALIDATION_DIR/ldd.txt" &
child_pid=$!
wait_for_child
[[ $status == 0 ]] || exit "$status"
! grep -q 'not found' "$VALIDATION_DIR/ldd.txt" || { echo "unresolved shared library" >&2; exit 1; }
"$PALACE_BIN" --help > "$VALIDATION_DIR/palace-help.txt" 2>&1 &
child_pid=$!
wait_for_child
[[ $status == 0 ]] || exit "$status"
sha256sum "$PALACE_BIN" "$PALACE_MPIRUN" "$build_receipt" > "$VALIDATION_DIR/identities.sha256" &
child_pid=$!
wait_for_child
[[ $status == 0 ]] || exit "$status"

for i in "${!case_ids[@]}"; do
  case_id=${case_ids[$i]}
  run_dir=$VALIDATION_DIR/$case_id
  run_dirs[$i]=$run_dir
  "$runner" "$manifest" "$case_id" "$run_dir" &
  child_pid=$!
  states[$i]=RUNNING
  write_summary
  wait_for_child
  statuses[$i]=$status
  if [[ $status == 0 ]]; then
    states[$i]=COMPLETE
  else
    states[$i]=FAILED
  fi
  write_summary
  [[ $status == 0 ]] || exit "$status"
done

printf 'Public-case process validation complete. Summary: %s\n' "$summary"
