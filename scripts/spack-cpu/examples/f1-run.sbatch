#!/usr/bin/env bash
#SBATCH --job-name=palace-run
#SBATCH --account=EDIT_ACCOUNT
#SBATCH --partition=ct112
#SBATCH --nodes=1
#SBATCH --ntasks=112
#SBATCH --cpus-per-task=1
#SBATCH --time=01:00:00
#SBATCH --signal=B:TERM@60
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err
set -euo pipefail

# Copy this file outside the checkout, then edit these four values.
PREPARATION="$HOME/opt/palace-spack/preparations/EDIT_PREPARATION_ID"
INPUT_DIR="/EDIT/absolute/input-directory"
INPUT_MANIFEST="/EDIT/absolute/input.sha256"
CONFIG="EDIT-relative-config.json"

# Run outputs are always separate from the immutable input and preparation.
RUN_ROOT="$HOME/palace-runs"
RUN_PACKAGE="$PREPARATION/source/palace/scripts/spack-cpu"

for value in "$PREPARATION" "$INPUT_DIR" "$INPUT_MANIFEST" "$CONFIG"; do
  [[ $value != *EDIT* ]] || { echo "edit every marked value before submitting" >&2; exit 2; }
done
runner=$RUN_PACKAGE/run-case.sbatch
[[ -f $runner ]] || { echo "prepared run script is missing: $runner" >&2; exit 1; }
mkdir -p "$RUN_ROOT"
export PREPARATION INPUT_DIR INPUT_MANIFEST CONFIG RUN_ROOT RUN_PACKAGE
exec "$runner"
