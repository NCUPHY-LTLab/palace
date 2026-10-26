# Install and validate Palace CPU with Spack

This workflow installs the fork of upstream `main` at `7d6b52486facb5717b3f29698a6fefc230033200` with its pinned dependencies.
The native project version is 0.18.1; `0.19.0-scq` is the archive-bound Spack
selector for the current-main dependency rules, not an upstream release.
It assumes you know how to edit, submit, and inspect Slurm jobs.
Preparation downloads on the login node; build and validation run offline on
compute nodes. No step submits or retries a job for you.

## 1. Clone

Clone the public `develop` branch and keep the checkout clean. Preparation
records its exact commit.

```bash
git clone --branch develop --single-branch \
  https://github.com/NCUPHY-LTLab/palace.git
cd palace
test -z "$(git status --porcelain)"
```

## 2. Build and install

On the F1 login node, prepare the sources, dependencies, public cases, and
editable Slurm files. Set the site's exact external Slurm prefix and version:

```bash
SLURM_PREFIX=/usr SLURM_SPACK_SPEC='slurm@=22-05-8-1' \
  scripts/spack-cpu/prepare.sh f1
```

Preparation prints a directory under
`$HOME/opt/palace-spack/jobs/<preparation-id>/`. This is a working directory
in your home quota, not scratch. It contains `build.sbatch`,
`validate.sbatch`, `logs/`, and `validation/`. The editable files come from
the [build](templates/build.sbatch.in) and
[validation](templates/validate.sbatch.in) templates. Repeating preparation
preserves edits to existing job files.

Edit the account, partition, CPUs, and time in `build.sbatch`; keep its one-node,
one-task shape. F1 defaults to eight CPUs and eight hours. Submit from the
printed job directory:

```bash
cd "$HOME/opt/palace-spack/jobs/<preparation-id>"
${EDITOR:-vi} build.sbatch
sbatch build.sbatch
```

Inspect `logs/palace-build-<jobid>.out` first, and its `.err` on failure.
Installation succeeds when Slurm reports `COMPLETED` with exit `0:0` **and**
`$HOME/opt/palace-spack/versions/<preparation-id>/BUILD-COMPLETE.sha256`
exists.

## 3. Validate

Edit the account, partition, MPI ranks, threads per rank, and time in
`validate.sbatch`; keep its one-node shape. F1 defaults to four ranks, one
thread per rank, and one hour. Submit from the same job directory:

```bash
${EDITOR:-vi} validate.sbatch
sbatch validate.sbatch
```

No input files are needed: the prepared public cases are `cavity2d-eigenmode`,
`cavity2d-electrostatic`, `cavity2d-driven`, and `cavity2d-transient`. Inspect
`validation/<jobid>/summary.tsv` first. Validation succeeds when all four
cases read `COMPLETE` there **and** Slurm reports `COMPLETED` with exit `0:0`.
For failures, inspect `logs/palace-validate-<jobid>.out` and its `.err`. A
failed or signaled case stops later cases; the scripts do not retry. Build
and public-case process validation do not establish scientific accuracy or
performance acceptance.

<details>
<summary>Other site and preparation notes</summary>

For LT Lab, use `prepare.sh ltlab` with that site's exact external Slurm
prefix and version. Its generated jobs contain `EDIT_PARTITION` rather than
F1's `ct112`; set the site's partition before submitting.

`CASE_BUNDLE` is optional and accepts only the checksum-bound historical
public comparison archive supplied by its owner. It is not needed for the
four bundled validation cases.

On F1, the `gcc/11.2.0` module seeds the locked compiler and MPI build. Use
the completed version's `run-env.sh` for later Palace runs, rather than the
seed module. Detailed package logs reside under the preparation's
`build-logs/`.

</details>
