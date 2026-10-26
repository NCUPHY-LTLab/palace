#!/usr/bin/env bash
# Custom single-case submission example. Bundled installation validation uses
# the prepare-generated validate.sbatch instead.
#SBATCH --job-name=palace-case
#SBATCH --account=EDIT_ACCOUNT
#SBATCH --partition=EDIT_PARTITION
#SBATCH --nodes=1
#SBATCH --ntasks=EDIT_RANKS
#SBATCH --cpus-per-task=EDIT_THREADS
#SBATCH --time=EDIT_TIME
#SBATCH --signal=B:TERM@60
#SBATCH --output=EDIT_LOG_DIRECTORY/%x-%j.out
#SBATCH --error=EDIT_LOG_DIRECTORY/%x-%j.err
set -euo pipefail

# EDIT: one completed preparation, sealed input, relative config, and output root.
PREPARATION="/EDIT/absolute/preparation"
INPUT_DIR="/EDIT/absolute/input"
INPUT_MANIFEST="/EDIT/absolute/input.sha256"
CONFIG="EDIT-relative-config.json"
RUN_BASE="/EDIT/absolute/run-root"

: "${SLURM_JOB_ID:?submit this script with sbatch}"
for value in "$PREPARATION" "$INPUT_DIR" "$INPUT_MANIFEST" "$RUN_BASE"; do
  [[ $value == /* && $value != *EDIT* ]] || { echo "edit every absolute path" >&2; exit 2; }
done
[[ $CONFIG != *EDIT* ]] || { echo "edit CONFIG" >&2; exit 2; }
[[ -d $RUN_BASE && ! -L $RUN_BASE ]] || { echo "RUN_BASE must be an existing nonsymlink directory" >&2; exit 2; }
RUN_DIR=$(realpath "$RUN_BASE")/$SLURM_JOB_ID
RUN_PACKAGE=$PREPARATION/source/palace/scripts/spack-cpu
core=$RUN_PACKAGE/run-case.sh
[[ -x $core ]] || { echo "frozen single-case core is missing: $core" >&2; exit 1; }
export PREPARATION INPUT_DIR INPUT_MANIFEST CONFIG RUN_DIR RUN_PACKAGE
exec "$core"
