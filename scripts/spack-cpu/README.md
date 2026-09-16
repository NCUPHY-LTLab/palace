# Install and validate Palace CPU with Spack

This guide assumes you already know how to edit an `sbatch` file, submit it,
and inspect a Slurm job and its logs. The three steps below prepare online on
the login node, build offline on a compute node, and validate the installed
program with four public cases bundled in this fork. The scripts never submit
another job or retry a failed job.

## 1. Clone

Clone the public fork's delivered CPU-install topic and keep the checkout
clean. This is a candidate topic rather than the stable default branch;
`prepare.sh` records the exact checked-out commit automatically.

```bash
git clone --branch codex/palace-018-cpu-spack --single-branch \
  https://github.com/arfiligol/palace.git
cd palace
git rev-parse HEAD
test -z "$(git status --porcelain)"
```

## 2. Build and install

On the login node, prepare the source and bootstrap mirrors and the concrete
dependency lock. This step uses the network but does not compile or submit a
job. Replace the Slurm version if the site reports a different external
installation.

```bash
SLURM_PREFIX=/usr SLURM_SPACK_SPEC='slurm@=22-05-8-1' \
  scripts/spack-cpu/prepare.sh f1
```

`prepare.sh` prints the absolute preparation path. Copy the
[build template](examples/f1-build.sbatch) and
[validation template](examples/f1-validate.sbatch) from that preparation into
a directory outside the checkout. The copies are meant to be edited; their
delegated build, verifier, and case-runner hashes still require a compatible
preparation.

```bash
prep=$HOME/opt/palace-spack/preparations/<printed-id>
jobs=$HOME/palace-jobs
mkdir -p "$jobs/logs"
cp "$prep/source/palace/scripts/spack-cpu/examples/f1-build.sbatch" \
  "$jobs/palace-build.sbatch"
cp "$prep/source/palace/scripts/spack-cpu/examples/f1-validate.sbatch" \
  "$jobs/palace-validate.sbatch"
cd "$jobs"
```

Edit `palace-build.sbatch`. Its `#SBATCH` lines contain the account, partition,
time, and CPU allocation; `PREPARATION` is the only path to edit. Then submit:

```bash
${EDITOR:-vi} palace-build.sbatch
sbatch palace-build.sbatch
```

The template delegates to the frozen `build.sbatch` in the preparation. That
script compiles one package at a time using `SLURM_CPUS_PER_TASK`, installs to
an immutable version directory under `$HOME/opt/palace-spack/versions`, and
publishes `BUILD-COMPLETE.sha256` only after the installed ELF, runtime
libraries, JIT headers, manifests, and build receipt verify. A package-stage
install without that marker is incomplete. Slurm writes the wrapper log to
`$HOME/palace-jobs/logs/palace-build-<jobid>.{out,err}`.

If a template reports an incompatible preparation, create a new preparation
from the same checkout and copy that preparation's template. Account, path,
resource, and log settings in the copied wrapper remain editable.

## 3. Validate

After the build job succeeds, edit `palace-validate.sbatch`. Set the account,
preparation path, validation output path, and the one-node rank/thread/time
allocation in the marked lines. The defaults request four MPI ranks, one
thread per rank, and one hour. Submit from the same external jobs directory:

```bash
${EDITOR:-vi} palace-validate.sbatch
sbatch palace-validate.sbatch
```

The template uses the preparation's immutable `CASES.json` and `run-one.sh`.
It runs these unchanged public fixtures sequentially and stops at the first
failure:

- `cavity2d-eigenmode`
- `cavity2d-electrostatic`
- `cavity2d-driven`
- `cavity2d-transient`

You do not provide a sample configuration or input manifest. Each case gets a
new directory below
`<VALIDATION_ROOT>/<jobid>/<case-id>/<jobid>/`; existing output is never
overwritten. `<VALIDATION_ROOT>/<jobid>/summary.tsv` records each case as
`COMPLETE`, `FAILED`, or `UNATTEMPTED` and records its process exit status.
The Slurm wrapper log is
`$HOME/palace-jobs/logs/palace-validate-<jobid>.{out,err}`. A time-limit signal
is forwarded to the active case; later cases remain unattempted.

For each case, `PROCESS-RECEIPT.json`, `solver.stdout`, `solver.stderr`,
`native-resolved.json`, and `OUTPUTS.sha256` are the detailed records. A
`PROCESS_COMPLETE` receipt means the executable returned zero for that public
case. It is process validation, not a scientific-accuracy or performance
claim. `FAILED` or a nonzero Slurm state requires inspecting the corresponding
case and wrapper logs; the scripts do not retry automatically.
