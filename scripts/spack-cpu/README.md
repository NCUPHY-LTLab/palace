# Palace CPU with Spack

Use the installed Palace CPU environment to run a case prepared by SCGSim, or
follow the one-time installation path when a Palace version has not yet been
installed at the target site. Preparation and installation remain separate
from routine case submission.

## Run a prepared SCGSim case on F1

**Prerequisite:** the notebook's site setup must already select the installed
Palace runtime and a compatible Python. SCGSim supports Python 3.12 for this
handoff, but a compatible recorder Python has not yet been verified on F1; the
known F1 Python 3.6 and 3.8 installations are insufficient. This target path is
therefore not yet end-to-end validated on F1.

### 1. Package the prepared case locally

From the parent directory containing the newly prepared run folder and its
unchanged sibling `<run>.tar.gz`, put both into one transport archive:

```bash
run_id=my-case  # replace with the fresh name used in the notebook
tar -czf "${run_id}-submission.tar.gz" "$run_id" "${run_id}.tar.gz"
```

### 2. Transfer through the F1 DTN

Create the destination through the login node, then transfer the one outer
archive through the data-transfer endpoint. `scp -s` selects SFTP mode; it
does not run a shell on the DTN.

```bash
ssh f1-login 'mkdir -p palace-runs'
scp -s "${run_id}-submission.tar.gz" f1-dtn:palace-runs/
```

### 3. Extract and submit from the F1 login node

Log in through `f1-login`, not the DTN:

```bash
ssh f1-login
```

At the F1 shell prompt:

```bash
cd palace-runs
run_id=my-case  # the same fresh name used above
tar -xzf "${run_id}-submission.tar.gz"
cd "$run_id"
sbatch run_palace.sbatch
```

Submit from the extracted run directory: the generated Slurm script uses
`SLURM_SUBMIT_DIR` as that directory's runtime location.

Keep the original sibling `<run>.tar.gz` beside the returned run directory when
copying results back for SCGSim resolution.

### SCGSim runtime and archive reference

In the local notebook's handoff controls, select the F1 account and resources,
the exact installed Palace executable and `mpirun`, and the versioned
`run-env.sh`. Setup commands source `run-env.sh`, prepend a site-approved
directory containing the selected compatible `python3` to `PATH`, and then
restore `OMP_NUM_THREADS` from `PALACE_THREADS`. The installed Spack runtime
does not need a manual compiler or MPI module load.

`prepare_handoff()` writes the run directory and seals its sibling
`<run>.tar.gz` before writing
`metadata/palace_resource_record.json` into the directory. The manual outer
archive must therefore contain the complete run directory, including that
record, plus the unchanged sibling archive. The outer archive is transport
packaging, while the sibling archive remains the integrity authority required
for return and resolution. The package carries the case and recorder; it is
not a relocatable Palace installation.

At execution, SCGSim records observed executable provenance and runs Palace's
native configuration dry-run. It does not repeat full Spack build/store
verification, prove an expected runtime-hash match, or independently pin the
Python interpreter identity.

See the source-pinned SCGSim
[execution profiles](https://github.com/OrPenStrike/scgsim/blob/b9a6b1da8c7f9c9ac83ff794cab16171b074549c/docs/execution-profiles.qmd),
[Notebook handoff contract](https://github.com/OrPenStrike/scgsim/blob/b9a6b1da8c7f9c9ac83ff794cab16171b074549c/docs/notebook-ux.qmd),
and [Palace handoff source](https://github.com/OrPenStrike/scgsim/blob/b9a6b1da8c7f9c9ac83ff794cab16171b074549c/src/scgsim/palace/handoff.py)
for the exact controls and binding details. The
[advanced manual runner](#advanced-run-a-non-scgsim-case-manually) below is a
separate non-SCGSim entry point.

## Install Palace once on F1

Installation preparation runs online on the login node. Compilation runs later
inside an offline compute job. Use one clean checkout at the exact delivered
revision:

```bash
git clone https://github.com/arfiligol/palace.git
cd palace
git fetch origin <delivered-revision>
git switch --detach <delivered-revision>
test -z "$(git status --porcelain)"
```

Prepare sources and the dependency lock on the login node. This downloads and verifies
inputs but does not compile or submit a job:

```bash
SLURM_PREFIX=/usr SLURM_SPACK_SPEC=slurm@=22-05-8-1 \
  scripts/spack-cpu/prepare.sh f1
```

Copy the [F1 build template](examples/f1-build.sbatch) outside the clean
checkout. Edit its `--account` and `PREPARATION` lines using the path printed by
`prepare.sh`, then submit it. It delegates first to the frozen build script and
then to the frozen non-solving validation script in that preparation:

```bash
jobs=$HOME/palace-jobs
mkdir -p "$jobs/logs"
cp scripts/spack-cpu/examples/f1-build.sbatch "$jobs/my-palace-build.sbatch"
cd "$jobs"
${EDITOR:-vi} my-palace-build.sbatch
sbatch my-palace-build.sbatch
```

The build template fails visibly while any `EDIT` placeholder remains and never
submits a follow-up job. The F1 bootstrap GCC module is installation-only; a
prepared SCGSim case later activates the installed compiler and MPI runtime by
sourcing the versioned `run-env.sh`. See the
[detailed reference](#detailed-reference) for receipts, validation, resource
changes, failure handling, optional comparison inputs, and LT Lab usage.

## Detailed reference

This workflow prepares one pinned Palace 0.18 CPU dependency graph for LT Lab and F1 while keeping each site's compiler, scheduler, filesystem, and Slurm launch details separate. It is **CONVERGING**: preparation does not compile or run Palace, and the build and validation jobs require separate phase-2 authorization.

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

Preparation records the delivered Git revision and tree separately from the historically
named `solver_content_manifest_sha256`. That value currently binds every tracked Git entry
except `scripts/spack-cpu/` and `spack_repo/`, including documentation, tests, and workflows;
it is broader than native solver source. A source archive and its SHA-256 remain the full
build-source authority, and the manifest is additive. A matching completed preparation is
verified and reused; conflicting or incomplete directories fail visibly.

The prepared bootstrap store is fixed at `preparations/<id>/spack-cache/bootstrap` and
remains part of the immutable preparation. Each build job receives a separate writable
cache at `versions/<id>/spack-cache/<slurm-job-id>`; Spack's source cache resolves below
that job cache, and its only build stage is the sibling `stage` directory. The build
receipt records the effective user cache, source cache, build stage, and bootstrap
root without freezing the writable cache contents.

Preparation always copies the small public `cavity2d` eigenmode, electrostatic, driven,
and transient examples. `CASE_BUNDLE` is optional. When absent, the preparation contains
only those public cases. When explicitly set, it must be the known historical Xmon archive
with SHA-256 `c73772d1e8f739c3f174eecffb4a2b8bc5df7b2c622aa7302d4ea3adc09cdff6`;
the archive is retained unchanged and its verified configuration and mesh and four
one-pointer comparisons are staged. The case mode and identity are part of the plan key,
so public-only and Xmon preparations cannot alias. Existing schema-2 Xmon preparations
remain valid and are never rewritten. `cases/CASES.json` and generated `cases/run-one.sh`
are unexecuted phase-2 fixtures, not durable tests.

Each site must provide the exact external Slurm identity used by its `srun`. Spack is forbidden from building Slurm. The selected numerical graph is x86-64, GCC 15.2.0, Open MPI 5.0.10 with Fortran and explicit UCX/OFI and Slurm support, LP64 OpenBLAS 0.3.34 with pthreads and locking, Palace/MFEM/HYPRE/PETSc/SUNDIALS OpenMP, and SuperLU_DIST without OpenMP. Shared libraries include Palace, OpenBLAS, zlib, MFEM, libCEED, LIBXSMM, MUMPS, and SuperLU_DIST. Runtime uses one OpenMP and one OpenBLAS thread unless a later accepted run contract says otherwise.

F1's candidate site profile loads `gcc/11.2.0`; its actual module and Slurm identities still require authenticated site verification. LT Lab requires GCC 11.4.0. `prepare.sh` records the compiler paths and versions it actually sees.
The F1 profile consistently uses `/usr/bin/python3.8`, including Spack and generated
helpers. Python must be CPython 3.8 or newer and must retain the prepared major/minor,
SOABI, extension suffix, architecture, and executable prefix. The running executable
path and the required `ssl`, `sqlite3`, `ctypes`, `hashlib`, and `json` imports are
checked on every build and validation node. The exact preparation and runtime Python
versions and executable hashes remain provenance; a micro-version or byte difference
does not by itself reject a compatible interpreter. The manifest-bound prepared
clingo extension must import successfully and instantiate `clingo.Control` before any
build work. Schema-1 preparations are diagnostic history and cannot be used for a new
production build; rerun preparation with the current scripts.

The Python used for Spack preparation and generic Palace verification is not
the Python contract for SCGSim's copied recorder. Source inspection establishes
3.9 only as a technical floor, not a tested or supported configuration; the
SCGSim package declares `~=3.12.0` and supports Python 3.12 for this handoff.
That path has not been runtime-tested on F1, and availability of the
interpreter there is not established. F1's
current default `python3` is 3.6.8, and this preparation's
`/usr/bin/python3.8` verifier is also insufficient. The notebook's site setup
must prepend a site-approved directory containing the selected `python3` to
`PATH`; pointing `PATH` at `/usr/bin` does not select a compatible interpreter.
The recorder uses the standard library and is copied into the run, so remote
SCGSim installation is unnecessary. Current receipts do not independently pin
or record the selected interpreter identity.

## Prepare on a login node

Clone the public fork, select the exact delivered revision, and require a clean checkout.
Preparation downloads and checksum-verifies all source inputs, uses only Spack's prebuilt
bootstrap method, concretizes without compiling, then creates separate bootstrap and source
mirrors. It never submits a job.

```bash
git clone https://github.com/arfiligol/palace.git
cd palace
git fetch origin <delivered-revision>
git switch --detach <delivered-revision>
test -z "$(git status --porcelain)"
```

```bash
export SLURM_PREFIX=/usr
export SLURM_SPACK_SPEC='slurm@=23-11-11-1'  # replace with the exact site identity
scripts/spack-cpu/prepare.sh ltlab
```

Set `CASE_BUNDLE=/absolute/path/to/owner-provided.tar.gz` before this command only when
the exact historical Xmon bundle is available. There is no public download URL.

For F1, run the equivalent command yourself after login and after verifying the site values:

```bash
export SLURM_PREFIX=/usr
export SLURM_SPACK_SPEC='slurm@=<verified-site-version>'
scripts/spack-cpu/prepare.sh f1
```

F1 commands remain Human-operated. The F1 compute nodes have no external network, so preparation must finish on the login node before any build job. A preparation is not an F1 lock until its concrete `spack.lock` records the verified F1 compiler and external Slurm identities.

## Build under Slurm

The script has no resource defaults and never submits itself. Create the scheduler output directory first, then supply the site's partition, account, time, and one `cpus-per-task` value to `sbatch`. The script uses `SLURM_CPUS_PER_TASK` as Spack's only build parallelism and forces one package build at a time. Compiler, dependency, and Palace stages are resumable through Spack's installed database; a completed version is checksum-verified and not overwritten.

Before checking or installing packages, each build writes an immutable per-job Python
identity log under the preparation's `build-logs` directory. A successful build receipt
binds that runtime record to the exact preparation receipt, plan key, and prepared
Python compatibility contract.

The installed application identity is the regular Linux x86-64 ELF at
`<palace-prefix>/bin/palace-x86_64.bin`. Launcher scripts and symlinks are not accepted
as the executable authority. A package-stage install does not constitute a completed
installation: the full installed-store manifests, direct ELF identity, dynamic-library
record, runtime activation, and `BUILD-COMPLETE.sha256` must all verify. Failures after
the build starts leave a phase, source line, and exit status receipt in the
preparation's `build-logs` directory.

A tentative F1 single-node preparation command is shown only as a resource example; its time and memory have not been measured. `ct112` provides 4308 MB per requested core and accepts 1--112 cores with a 96-hour limit. Do not add a conflicting `--mem` request.

```bash
prep=$HOME/opt/palace-spack/preparations/<id>
mkdir -p "$HOME/opt/palace-spack/logs/<id>"
build_script=$prep/source/palace/scripts/spack-cpu/build.sbatch
sbatch --partition=ct112 --account=<account> --nodes=1 --ntasks=1 \
  --cpus-per-task=8 --time=08:00:00 \
  --output="$HOME/opt/palace-spack/logs/<id>/build-%j.out" \
  --export=ALL,PREPARATION="$prep" "$build_script"
```

For LT Lab, replace the site-specific scheduler arguments. Do not run two Spack builds against the same preparation concurrently.

## Validate after an authorized build

`validate.sbatch` verifies the immutable build receipt, the full owned Spack-store file
and symbolic-link manifests (including the shared numerical, MPI/PRRTE/PMIx, GCC runtime,
and JIT closure), executable hash, dynamic-library resolution, libCEED JIT-source
installation and runtime activation path, and Palace's non-solving `--help` startup. It
does not execute libCEED JIT code and does not claim numerical or F1 runtime validation.

```bash
validate_script=$prep/source/palace/scripts/spack-cpu/validate.sbatch
sbatch <site-resource-options> \
  --output="$HOME/opt/palace-spack/logs/<id>/validate-%j.out" \
  --export=ALL,PREPARATION="$prep" "$validate_script"
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

## Advanced: run a non-SCGSim case manually

This generic runner is for a manually assembled case that was not prepared by
SCGSim. `run-case.sbatch` accepts one sealed, self-contained input directory
without changing its configuration bytes. Create a SHA-256 manifest outside
that directory; it must list every regular input file exactly once. Symbolic
links, unlisted files, duplicate names, absolute paths, and `..` paths fail
before Palace starts.

```bash
input=/absolute/path/to/input
(cd "$input" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
  > /absolute/path/to/input.sha256
```

The runner first verifies the preparation and completed build using the preparation's own
frozen verifier. It copies the inputs to a new `$RUN_ROOT/$SLURM_JOB_ID` directory, then
runs the installed Palace ELF once with `--dry-run`. Palace itself preprocesses comments,
trailing commas, and integer ranges and emits resolved JSON; the helper parses only that
emitted JSON. `Model/Mesh` and optional `Model/Partitioning` must name manifest-bound
relative files, and `Problem/Output` must be a relative path that does not overlap input.
This is a contained-path check for Palace's filesystem fields, not a sandbox for arbitrary
configuration behavior.

For a preparation created before this runner was delivered, stage the reviewed two-file
run package separately; do not modify the immutable preparation. `RUN_PACKAGE` is the
absolute directory containing byte-exact `run-case.sbatch` and `run_case.py`. The submitted
spool copy must match that authority, and their hashes are recorded separately from the
installed source and executable identities.

Verify a transferred package from inside its directory so the manifest's relative names
remain portable: `(cd "$RUN_PACKAGE" && sha256sum -c MANIFEST.sha256)`.

```bash
run_package=/absolute/path/to/reviewed-run-package
mkdir -p /absolute/path/to/run-root /absolute/path/to/slurm-logs
sbatch <site-account-and-partition> --nodes=1 --ntasks=112 --cpus-per-task=1 \
  --time=01:00:00 --output=/absolute/path/to/slurm-logs/%j.out \
  --error=/absolute/path/to/slurm-logs/%j.err \
  --export=ALL,PREPARATION="$prep",INPUT_DIR="$input",INPUT_MANIFEST=/absolute/path/to/input.sha256,CONFIG=config.json,RUN_ROOT=/absolute/path/to/run-root,RUN_PACKAGE="$run_package" \
  "$run_package/run-case.sbatch"
```

No account, partition, case name, rank count, or thread count is built into the runner.
For a 112-CPU single-node comparison, submit at most one authorized job at a time with
`112x1`, `56x2`, `28x4`, or `14x8` ranks by threads. The runner sets
`OMP_NUM_THREADS` from `SLURM_CPUS_PER_TASK`, disables dynamic OpenMP, binds threads close
to cores, keeps OpenBLAS at one thread, clears inherited Open MPI/PMIx/PRRTE overrides and
`LD_PRELOAD`, and launches the installed `mpirun` without oversubscription. It never submits
another resource shape. A lower-rank follow-up is justified only by the exact native error
`Mesh partitioning must have parts <= mesh elements (<ranks> vs. <elements>)!` when no
partitioning file was supplied; partition-file mismatches, timeouts, signals, MPI errors,
and solver failures stop the sequence.

The job writes staging, native dry-run, runtime, solver, input, output-hash, and atomic
process receipts. Exit zero means process completion only; scientific acceptance remains
unset. Slurm sends `TERM` to the batch script 60 seconds before its time limit when the site
supports `--signal=B:TERM@60`; the script records and forwards observed `TERM`/`INT`.
Scheduler termination can still prevent the final receipt, so scheduler accounting and the
Slurm log remain authoritative. For AMR, atomically written
`<Problem.Output>/palace.json` with `Problem/Iteration` equal to 1 proves the initial
solve/estimate returned; a value of 2 is the first durable proof that one refined AMR
solve/estimate cycle completed. Archive creation or progress log lines alone are weaker
evidence and are not convergence thresholds.

The current generic graph enables UCX and OFI, but concretization alone does not establish a high-speed site transport. Its resolved UCX has verbs, RDMA-CM, RC, and UD disabled, and libfabric resolves socket/TCP/UDP providers. Phase 2 must record actual Open MPI component selection and site transport before any multinode performance claim or transport change.
