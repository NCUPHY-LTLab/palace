#!/usr/bin/env bash
#SBATCH --job-name=palace-spack-build
set -euo pipefail

: "${SLURM_JOB_ID:?submit this script with sbatch}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
[[ $SLURM_CPUS_PER_TASK =~ ^[1-9][0-9]*$ ]] || { echo "SLURM_CPUS_PER_TASK must be positive" >&2; exit 2; }
[[ $SLURM_NTASKS == 1 ]] || { echo "build job requires exactly one task" >&2; exit 2; }
: "${PREPARATION:?set PREPARATION to an absolute prepared directory}"
[[ $PREPARATION == /* ]] || { echo "PREPARATION must be absolute" >&2; exit 2; }
[[ $PREPARATION =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported PREPARATION path characters" >&2; exit 2; }
verify="$PREPARATION/source/palace/scripts/spack-cpu/verify.py"
[[ -f $verify ]] || { echo "immutable preparation verifier missing" >&2; exit 1; }
python=$(awk -F'"' '$2 == "python" {print $4}' "$PREPARATION/PREPARED.json")
[[ $python == /* && -x $python ]] || { echo "prepared Python interpreter missing" >&2; exit 1; }
"$python" "$verify" prepared "$PREPARATION"

readarray -t fields < <("$python" - "$PREPARATION/PREPARED.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
for key in ("site", "preparation_revision", "environment", "version_root"):
    print(record[key])
PY
)
site=${fields[0]}
revision=${fields[1]}
environment=${fields[2]}
version=${fields[3]}
[[ -d $environment && -d $version ]]
if [[ $site == f1 ]]; then
  command -v module >/dev/null
  module purge
  module load gcc/11.2.0
  [[ $(gcc -dumpfullversion) == 11.2.0 ]]
else
  [[ $site == ltlab && $(gcc -dumpfullversion) == 11.4.0 ]]
fi

if [[ -f $version/BUILD-COMPLETE.sha256 ]]; then
  "$python" "$verify" build "$PREPARATION"
  echo "verified existing complete build: $version"
  exit 0
fi
lock_dir=$version/.build-writer
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "another build owns this version; owner follows:" >&2
  cat "$lock_dir/owner.txt" >&2 2>/dev/null || true
  exit 1
fi
completion_tmp=$version/.completion.$SLURM_JOB_ID
cleanup() {
  [[ ! -d $completion_tmp ]] || rm -rf -- "$completion_tmp"
  if [[ ! -f $version/BUILD-COMPLETE.sha256 ]]; then
    rm -f -- "$version/run-env.sh" "$version/ldd.txt" "$version/INSTALL-MANIFEST.sha256" \
      "$version/INSTALL-LINKS.sha256" "$version/BUILD-RECEIPT.json"
  fi
  if [[ -f $lock_dir/owner.txt ]] && [[ $(cat "$lock_dir/owner.txt") == "$SLURM_JOB_ID" ]]; then rm "$lock_dir/owner.txt" && rmdir "$lock_dir"; fi
}
trap cleanup EXIT
printf '%s\n' "$SLURM_JOB_ID" > "$lock_dir/owner.txt"
if [[ ! -f $version/BUILD-COMPLETE.sha256 ]]; then
  rm -f -- "$version/run-env.sh" "$version/ldd.txt" "$version/INSTALL-MANIFEST.sha256" \
    "$version/INSTALL-LINKS.sha256" "$version/BUILD-RECEIPT.json"
fi

spack=$(find "$PREPARATION/spack-unpack" -mindepth 3 -maxdepth 3 -path '*/bin/spack' -type f -print -quit)
[[ -x $spack ]] || { echo "prepared Spack executable missing" >&2; exit 1; }
export SPACK_USER_CONFIG_PATH="$PREPARATION/spack-config"
export SPACK_USER_CACHE_PATH="$PREPARATION/spack-cache"
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ftp_proxy=http://127.0.0.1:9
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy FTP_PROXY=$ftp_proxy NO_PROXY= no_proxy=
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_PROC_BIND=close OMP_PLACES=cores
logs="$PREPARATION/build-logs"
mkdir -p "$logs" "$version/stages"
"$python" "$spack" bootstrap status > "$logs/bootstrap-status.txt"
"$python" "$spack" -e "$environment" mirror list > "$logs/mirrors.txt"
if awk 'NF >= 2 && $2 !~ /^file:\/\//' "$logs/mirrors.txt" | grep -q .; then echo "non-local Spack mirror is enabled" >&2; exit 1; fi
"$python" "$spack" -e "$environment" fetch -D -m > "$logs/offline-fetch-proof.txt" 2>&1

stage() {
  local name=$1
  shift
  "$@" 2>&1 | tee "$logs/$name.log"
  "$python" "$spack" -e "$environment" find --format '{name} {version} {hash}' > "$logs/$name.verify.txt"
  sha256sum "$logs/$name.log" "$logs/$name.verify.txt" > "$version/stages/$name.complete"
}
stage compiler "$python" "$spack" -e "$environment" install --only-concrete --fail-fast -p 1 -j "$SLURM_CPUS_PER_TASK" 'gcc@=15.2.0'
stage dependencies "$python" "$spack" -e "$environment" install --only-concrete --only dependencies --fail-fast -p 1 -j "$SLURM_CPUS_PER_TASK" 'local.palace@=0.18.0-scq'
stage palace "$python" "$spack" -e "$environment" install --only-concrete --only package --fail-fast -p 1 -j "$SLURM_CPUS_PER_TASK" 'local.palace@=0.18.0-scq'

prefix=$("$python" "$spack" -e "$environment" location -i 'local.palace@=0.18.0-scq')
binary="$prefix/bin/palace"
[[ -x $binary ]] || binary="$prefix/bin/palace-x86_64.bin"
[[ -x $binary ]] || { echo "installed Palace executable not found in $prefix/bin" >&2; exit 1; }
binary=$(realpath "$binary")
libceed_prefix=$("$python" "$spack" -e "$environment" location -i libceed)
jit="$libceed_prefix/include/ceed/jit-source"
[[ -d $jit ]] && find "$jit" -type f -print -quit | grep -q . || { echo "libCEED JIT headers missing" >&2; exit 1; }
openmpi_prefix=$("$python" "$spack" -e "$environment" location -i openmpi)
prrte_prefix=$("$python" "$spack" -e "$environment" location -i prrte)
pmix_prefix=$("$python" "$spack" -e "$environment" location -i pmix)
gcc_prefix=$("$python" "$spack" -e "$environment" location -i 'gcc@=15.2.0')
mpirun=$(realpath "$openmpi_prefix/bin/mpirun")
[[ -x $mpirun && -x $gcc_prefix/bin/gcc ]]
[[ ! -e $completion_tmp ]] || { echo "completion staging path already exists" >&2; exit 1; }
mkdir "$completion_tmp"
"$python" "$spack" -e "$environment" load --sh 'local.palace@=0.18.0-scq' > "$completion_tmp/run-env.sh"
cat >> "$completion_tmp/run-env.sh" <<EOF
export PALACE_BIN='$binary'
export PALACE_MPIRUN='$mpirun'
export CEED_JIT_SOURCE_ROOT='$jit'
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores
EOF
ldd "$binary" > "$completion_tmp/ldd.txt"
! grep -q 'not found' "$completion_tmp/ldd.txt" || { echo "unresolved shared library" >&2; exit 1; }

find "$version/store" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$completion_tmp/INSTALL-MANIFEST.sha256"
find "$version/store" -type l -printf '%p -> %l\n' | LC_ALL=C sort | sha256sum > "$completion_tmp/INSTALL-LINKS.sha256"
binary_sha=$(sha256sum "$binary" | awk '{print $1}')
"$python" - "$completion_tmp/BUILD-RECEIPT.json" "$revision" "$site" "$SLURM_JOB_ID" "$SLURM_CPUS_PER_TASK" "$version/store" "$prefix" "$binary" "$binary_sha" "$jit" "$libceed_prefix" "$openmpi_prefix" "$mpirun" "$prrte_prefix" "$pmix_prefix" "$gcc_prefix" <<'PY'
import json, sys
keys = ("preparation_revision", "site", "slurm_job_id", "slurm_cpus_per_task", "install_store", "palace_prefix", "palace_binary", "palace_binary_sha256", "libceed_jit_source", "libceed_prefix", "openmpi_prefix", "mpirun", "prrte_prefix", "pmix_prefix", "gcc_prefix")
record = {"schema": 1, "state": "BUILD_COMPLETE", "semantic_state": "CONVERGING", "openmp_num_threads": 1, "openblas_num_threads": 1, "omp_proc_bind": "close", "omp_places": "cores"}
record.update(dict(zip(keys, sys.argv[2:])))
open(sys.argv[1], "w").write(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
"$python" - "$completion_tmp/INSTALL-MANIFEST.sha256" "$completion_tmp/INSTALL-LINKS.sha256" "$version/store" <<'PY'
import hashlib, os, sys
from pathlib import Path
manifest, links, root = map(Path, sys.argv[1:])
def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()
for line in manifest.read_text().splitlines():
    expected, name = line.split("  ", 1)
    path = Path(name)
    if not path.is_file() or digest(path) != expected:
        raise SystemExit("staged install manifest mismatch: " + name)
actual = []
for path in sorted(root.rglob("*"), key=lambda p: str(p)):
    if path.is_symlink():
        actual.append("{0} -> {1}\n".format(path, os.readlink(str(path))))
expected = links.read_text().split()[0]
if hashlib.sha256("".join(actual).encode()).hexdigest() != expected:
    raise SystemExit("staged install symlink manifest mismatch")
PY
for name in run-env.sh ldd.txt INSTALL-MANIFEST.sha256 INSTALL-LINKS.sha256 BUILD-RECEIPT.json; do
  [[ ! -e $version/$name ]] || { echo "incomplete completion artifact already exists: $version/$name" >&2; exit 1; }
  mv "$completion_tmp/$name" "$version/$name"
done
chmod 0444 "$version/run-env.sh" "$version/ldd.txt" "$version/INSTALL-MANIFEST.sha256" "$version/INSTALL-LINKS.sha256" "$version/BUILD-RECEIPT.json"
"$python" "$verify" artifacts "$PREPARATION"
sha256sum "$version/BUILD-RECEIPT.json" > "$completion_tmp/BUILD-COMPLETE.sha256"
chmod 0444 "$completion_tmp/BUILD-COMPLETE.sha256"
mv "$completion_tmp/BUILD-COMPLETE.sha256" "$version/BUILD-COMPLETE.sha256"
rmdir "$completion_tmp"
echo "build complete: $binary"
