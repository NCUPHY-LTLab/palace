# Install and validate Palace CPU with Spack

This guide assumes you already know how to edit an `sbatch` file, submit it,
and inspect Slurm state and logs. Preparation runs online on the login node;
the generated build and validation jobs run on compute nodes without network
access. Nothing here submits or retries a job automatically.

## 1. Clone

Clone the public CPU-install topic and keep the checkout clean. Preparation
records the exact checked-out commit and source tree.

```bash
git clone --branch codex/palace-018-cpu-spack --single-branch \
  https://github.com/arfiligol/palace.git
cd palace
git rev-parse HEAD
test -z "$(git status --porcelain)"
```

## 2. Build and install

Set the site's external Slurm identity and prepare all immutable sources,
bootstrap tools, dependency locks, public cases, and job files. This command
downloads and verifies inputs but does not compile or submit a job.

```bash
SLURM_PREFIX=/usr SLURM_SPACK_SPEC='slurm@=22-05-8-1' \
  scripts/spack-cpu/prepare.sh f1
```

For LT Lab, use `prepare.sh ltlab` with that site's exact Slurm prefix and
version. The generated LT Lab files deliberately contain `EDIT_PARTITION`;
they never inherit F1's `ct112`. `CASE_BUNDLE` remains optional and accepts
only the checksum-bound historical public comparison archive when its owner
provides it. It is not required for the validation below.

After verification, preparation prints a directory under
`$HOME/opt/palace-spack/jobs/<preparation-id>/`. The directory contains
`build.sbatch`, `validate.sbatch`, `logs/`, and `validation/`. Their source
templates are [build](templates/build.sbatch.in) and
[validation](templates/validate.sbatch.in); preparation fills the absolute
paths automatically. Repeating preparation verifies and reuses the
preparation, creates missing job files, and preserves job files you already
edited.

Edit only the scheduler settings at the top of the generated `build.sbatch`:
account, partition, CPUs, and time. Keep its fixed one-node, one-task shape.
Its preparation and log paths are already absolute. F1 defaults to eight CPUs
and eight hours. Then submit exactly that file:

```bash
cd "$HOME/opt/palace-spack/jobs/<preparation-id>"
${EDITOR:-vi} build.sbatch
sbatch build.sbatch
```

The wrapper executes the frozen `build.sh` from its preparation. The F1
`gcc/11.2.0` module is only the seed used to build the locked GCC 15.2 and MPI
stack. A completed installation later uses its versioned `run-env.sh`; users
do not load the seed module to run Palace. Build phase output is in
`logs/palace-build-<jobid>.{out,err}`, detailed package logs are under the
preparation's `build-logs/`, and `BUILD-COMPLETE.sha256` is published only
after the direct ELF, libraries, JIT headers, manifests, activation, and
receipt verify.

## 3. Validate

After the build completes, edit the account, partition, MPI ranks, threads per
rank, and time at the top of the generated `validate.sbatch`. Keep its fixed
one-node shape. F1 defaults to four MPI ranks, one thread per rank, and one
hour. Submit it from the same job directory:

```bash
${EDITOR:-vi} validate.sbatch
sbatch validate.sbatch
```

The wrapper executes frozen `validate-public.sh`. It first verifies the
completed installation, dynamic-library resolution, and non-solving
`--help` startup. It then uses the preparation's immutable `CASES.json` and
plain `run-one.sh` adapter to run these unchanged public fixtures sequentially:

1. `cavity2d-eigenmode`
2. `cavity2d-electrostatic`
3. `cavity2d-driven`
4. `cavity2d-transient`

No sample configuration or input manifest is required. The job stops at the
first failed or signaled case and never starts later cases. Its authoritative
summary is `validation/<jobid>/summary.tsv`; each case directory is
`validation/<jobid>/<case-id>/`, without an extra repeated job ID. Wrapper
output is `logs/palace-validate-<jobid>.{out,err}`. `COMPLETE` means the Palace
process returned zero for that public case, not scientific accuracy or
performance acceptance.
