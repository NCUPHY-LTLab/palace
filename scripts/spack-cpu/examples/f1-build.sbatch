#!/usr/bin/env bash
# EDIT: scheduler resources for this build job.
#SBATCH --job-name=palace-build
#SBATCH --account=EDIT_ACCOUNT
#SBATCH --partition=ct112
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=08:00:00
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err
set -euo pipefail

# EDIT: set this to the path printed by prepare.sh.
PREPARATION="$HOME/opt/palace-spack/preparations/EDIT_PREPARATION_ID"

[[ $PREPARATION != *EDIT_* ]] || { echo "edit PREPARATION before submitting" >&2; exit 2; }
build_script=$PREPARATION/source/palace/scripts/spack-cpu/build.sbatch
verify_script=$PREPARATION/source/palace/scripts/spack-cpu/verify.py
[[ -f $build_script && -f $verify_script ]] || { echo "prepared build or verification script is missing" >&2; exit 1; }
expected_build_sha=10ebb2c0dfb32955e57ec2bc555dfb9485f8790b70c51bdb3df8d29aa80675b4
expected_verify_sha=319fd444c3c5bfb8acc70fff5926697cbb35c1ab54b70dd40815ca2a6aa6336e
[[ $(sha256sum "$build_script" | awk '{print $1}') == "$expected_build_sha" &&
   $(sha256sum "$verify_script" | awk '{print $1}') == "$expected_verify_sha" ]] || {
  echo "preparation is incompatible with this build template; create a matching preparation" >&2
  exit 1
}
export PREPARATION
exec "$build_script"
