# Common CPU Spack preparation

This workflow prepares one pinned Palace 0.18 CPU dependency graph for LT Lab and F1 while keeping each site's compiler, scheduler, filesystem, and Slurm launch details separate. It is **PREPARED / CONVERGING**: the package has not been compiled or run on either site, and the build and validation jobs require separate phase-2 authorization.

The older `scripts/f1` workflow remains the historical fixed-`1ea14a84` lane. Do not use its prefix or receipts for this 0.18 build.

## Inputs and layout

`lock.json` pins Spack 1.2.0, the package repository snapshot, the Palace dependency snapshots, and the required recipe patches. `prepare.sh` creates:

```
$HOME/opt/palace-spack/
  cache/                    downloaded immutable inputs
  preparations/<id>/        source/bootstrap mirrors, concrete spack.lock, receipts
  versions/<id>/            the site-specific install store and completion receipt
  logs/<id>/                caller-selected Slurm output location
```

Preparation records the delivered Git revision and tree separately from a manifest hash of solver content that excludes the Spack workflow and recipe paths. A source archive and its SHA-256 remain the full build-source authority; the narrower manifest is additive. A matching completed preparation is verified and reused; conflicting or incomplete directories fail visibly.

Preparation also requires the exact owner-provided Xmon archive through `CASE_BUNDLE`. It retains the archive unchanged, extracts only the verified configuration and mesh for execution, prepares four one-pointer comparison configurations, and copies the small public `cavity2d` eigenmode, electrostatic, driven, and transient examples. `cases/CASES.json` and the generated `cases/run-one.sh` are an unexecuted phase-2 harness, not durable tests.

Each site must provide the exact external Slurm identity used by its `srun`. Spack is forbidden from building Slurm. The selected numerical graph is x86-64, GCC 15.2.0, Open MPI 5.0.10 with Fortran and explicit UCX/OFI and Slurm support, LP64 OpenBLAS 0.3.34 with pthreads and locking, Palace/MFEM/HYPRE/PETSc/SUNDIALS OpenMP, and SuperLU_DIST without OpenMP. Shared libraries include Palace, OpenBLAS, zlib, MFEM, libCEED, LIBXSMM, MUMPS, and SuperLU_DIST. Runtime uses one OpenMP and one OpenBLAS thread unless a later accepted run contract says otherwise.

F1's candidate site profile loads `gcc/11.2.0`; its actual module and Slurm identities still require authenticated site verification. LT Lab requires GCC 11.4.0. `prepare.sh` records the compiler paths and versions it actually sees.
The F1 profile consistently uses the already observed `/usr/bin/python3.8` (3.8.17),
including Spack and generated helpers, and records its executable hash. It does not use
F1's default Python 3.6 or install another interpreter. LT Lab records and reuses its
selected Python 3.8-or-newer interpreter the same way.

## Prepare on a login node

Use a clean clone at the exact delivered revision. Preparation downloads and checksum-verifies all source inputs, uses only Spack's prebuilt bootstrap method, concretizes without compiling, then creates separate bootstrap and source mirrors. It never submits a job.

```bash
export SLURM_PREFIX=/usr
export SLURM_SPACK_SPEC='slurm@=23-11-11-1'  # replace with the exact site identity
export CASE_BUNDLE=/absolute/path/to/owner-provided.tar.gz
scripts/spack-cpu/prepare.sh ltlab
```

For F1, run the equivalent command yourself after login and after verifying the site values:

```bash
export SLURM_PREFIX=/usr
export SLURM_SPACK_SPEC='slurm@=<verified-site-version>'
scripts/spack-cpu/prepare.sh f1
```

F1 commands remain Human-operated. The F1 compute nodes have no external network, so preparation must finish on the login node before any build job. A preparation is not an F1 lock until its concrete `spack.lock` records the verified F1 compiler and external Slurm identities.

## Build under Slurm

The script has no resource defaults and never submits itself. Create the scheduler output directory first, then supply the site's partition, account, time, and one `cpus-per-task` value to `sbatch`. The script uses `SLURM_CPUS_PER_TASK` as Spack's only build parallelism and forces one package build at a time. Compiler, dependency, and Palace stages are resumable through Spack's installed database; a completed version is checksum-verified and not overwritten.

A tentative F1 single-node preparation command is shown only as a resource example; its time and memory have not been measured. `ct112` provides 4308 MB per requested core and accepts 1--112 cores with a 96-hour limit. Do not add a conflicting `--mem` request.

```bash
prep=$HOME/opt/palace-spack/preparations/<id>
mkdir -p "$HOME/opt/palace-spack/logs/<id>"
sbatch --partition=ct112 --account=<account> --nodes=1 --ntasks=1 \
  --cpus-per-task=8 --time=08:00:00 \
  --output="$HOME/opt/palace-spack/logs/<id>/build-%j.out" \
  --export=ALL,PREPARATION="$prep" scripts/spack-cpu/build.sbatch
```

For LT Lab, replace the site-specific scheduler arguments. Do not run two Spack builds against the same preparation concurrently.

## Validate after an authorized build

`validate.sbatch` verifies the immutable build receipt, the full owned Spack-store file
and symbolic-link manifests (including the shared numerical, MPI/PRRTE/PMIx, GCC runtime,
and JIT closure), executable hash, dynamic-library resolution, libCEED JIT-source
installation and runtime activation path, and Palace's non-solving `--help` startup. It
does not execute libCEED JIT code and does not claim numerical or F1 runtime validation.

```bash
sbatch <site-resource-options> \
  --output="$HOME/opt/palace-spack/logs/<id>/validate-%j.out" \
  --export=ALL,PREPARATION="$prep" scripts/spack-cpu/validate.sbatch
```

Numerical validation begins with small public models before the released Xmon comparison. The Xmon archive is owner-provided and has no public download URL. Preserve its original mesh and configuration. The original configuration resolves the new default eigensolver to SLEPc and its `Default` linear solver to SuperLU priority; input hash equality therefore does not imply solver equality with the historical ARPACK build. Later controlled comparison copies change one JSON pointer at a time: `/Solver/Eigenmode/Type` (`SLEPc` or `ARPACK`) or `/Solver/Linear/Type` (`MUMPS` or `SuperLU`). Record every derived hash and resolved backend.

The prepared `run-one.sh` accepts only its canonical `CASES.json`. Before creating an
output directory it verifies the matching preparation and build, the bound runtime
activation, and every regular config, mesh, and support file in the selected case. It
clears inherited `OMPI_MCA_*`, `PMIX_MCA_*`, and `PRTE_MCA_*` overrides without choosing a
new transport. Each attempted process writes an atomic execution receipt with input,
build, binary, resources, timestamps, exit status, requested/resolved solver types, and
stdout/stderr hashes. An exit status of zero means only `PROCESS_COMPLETE`; scientific
acceptance remains unset while this scope is CONVERGING.

For future numerical jobs, use the installed Open MPI `mpirun` inside the Slurm allocation, derive ranks and threads from `SLURM_NTASKS` and `SLURM_CPUS_PER_TASK`, bind to cores, and do not oversubscribe. Multinode resource requests remain proposals until measured and authorized.

The current generic graph enables UCX and OFI, but concretization alone does not establish a high-speed site transport. Its resolved UCX has verbs, RDMA-CM, RC, and UD disabled, and libfabric resolves socket/TCP/UDP providers. Phase 2 must record actual Open MPI component selection and site transport before any multinode performance claim or transport change.
