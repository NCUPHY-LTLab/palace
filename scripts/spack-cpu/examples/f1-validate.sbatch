#!/usr/bin/env bash
# EDIT: scheduler resources for this validation job.
#SBATCH --job-name=palace-validate
#SBATCH --account=EDIT_ACCOUNT
#SBATCH --partition=ct112
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --time=01:00:00
#SBATCH --signal=B:TERM@60
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err
set -euo pipefail
umask 077

# EDIT: the preparation printed by prepare.sh and the validation output path.
PREPARATION="$HOME/opt/palace-spack/preparations/EDIT_PREPARATION_ID"
VALIDATION_ROOT="$HOME/palace-validation"

: "${SLURM_JOB_ID:?submit this script with sbatch}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
[[ $SLURM_NTASKS =~ ^[1-9][0-9]*$ && $SLURM_CPUS_PER_TASK =~ ^[1-9][0-9]*$ ]] || {
  echo "Slurm ranks and threads must be positive" >&2
  exit 2
}
for path in "$PREPARATION" "$VALIDATION_ROOT"; do
  [[ $path != *EDIT* && $path == /* ]] || { echo "edit every marked path to an absolute path" >&2; exit 2; }
done

manifest=$PREPARATION/cases/CASES.json
runner=$PREPARATION/cases/run-one.sh
prepare_cases=$PREPARATION/source/palace/scripts/spack-cpu/prepare_cases.py
run_case=$PREPARATION/source/palace/scripts/spack-cpu/run-case.sbatch
run_helper=$PREPARATION/source/palace/scripts/spack-cpu/run_case.py
[[ -f $manifest && -x $runner && -f $prepare_cases && -f $run_case && -f $run_helper ]] || {
  echo "prepared public cases or delegated runner files are missing" >&2
  exit 1
}
expected_prepare_cases_sha=81aedc3142b731314ac5338589477500d870d2d37e1f7ec089884084529d7d74
expected_run_case_sha=0a9224b442ce6a184d69da183345493a0b19e0a5ddbb4dec37592f9e36f6f454
expected_run_helper_sha=396985f36266e0f7c62e59e8721e9e39a51aef246f4a01abddc5a824817640ca
[[ $(sha256sum "$prepare_cases" | awk '{print $1}') == "$expected_prepare_cases_sha" &&
   $(sha256sum "$run_case" | awk '{print $1}') == "$expected_run_case_sha" &&
   $(sha256sum "$run_helper" | awk '{print $1}') == "$expected_run_helper_sha" ]] || {
  echo "preparation is incompatible with this validation template; create a matching preparation" >&2
  exit 1
}

mkdir -p "$VALIDATION_ROOT"
validation_root=$(realpath "$VALIDATION_ROOT")
job_dir=$validation_root/$SLURM_JOB_ID
[[ ! -e $job_dir ]] || { echo "validation job directory already exists: $job_dir" >&2; exit 1; }
mkdir "$job_dir"
summary=$job_dir/summary.tsv

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
    kill -TERM "$child_pid" 2>/dev/null || true
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
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

write_summary
for i in "${!case_ids[@]}"; do
  case_id=${case_ids[$i]}
  case_root=$job_dir/$case_id
  mkdir "$case_root"
  run_dirs[$i]=$case_root/$SLURM_JOB_ID
  "$runner" "$manifest" "$case_id" "$case_root" &
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
