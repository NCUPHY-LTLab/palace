#!/usr/bin/env bash
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

# Edit this one value after prepare.sh prints the preparation path.
PREPARATION="$HOME/opt/palace-spack/preparations/EDIT_PREPARATION_ID"

[[ $PREPARATION != *EDIT_* ]] || { echo "edit PREPARATION before submitting" >&2; exit 2; }
build_script=$PREPARATION/source/palace/scripts/spack-cpu/build.sbatch
validate_script=$PREPARATION/source/palace/scripts/spack-cpu/validate.sbatch
[[ -f $build_script && -f $validate_script ]] || { echo "prepared build or validation script is missing" >&2; exit 1; }
export PREPARATION
"$build_script"
exec "$validate_script"
