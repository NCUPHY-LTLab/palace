#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

: "${SLURM_JOB_ID:?submit this script with sbatch}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is required}"
: "${SLURM_NTASKS:?SLURM_NTASKS is required}"
[[ $SLURM_CPUS_PER_TASK =~ ^[1-9][0-9]*$ ]] || { echo "SLURM_CPUS_PER_TASK must be positive" >&2; exit 2; }
[[ $SLURM_NTASKS == 1 ]] || { echo "build job requires exactly one task" >&2; exit 2; }
: "${PREPARATION:?set PREPARATION to an absolute prepared directory}"
[[ $PREPARATION == /* ]] || { echo "PREPARATION must be absolute" >&2; exit 2; }
[[ $PREPARATION =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported PREPARATION path characters" >&2; exit 2; }
verify="$PREPARATION/source/palace/scripts/spack-cpu/verify.py"
helper="$PREPARATION/source/palace/scripts/spack-cpu/prepare.py"
[[ -f $verify && -f $helper ]] || { echo "immutable preparation verifier or helper missing" >&2; exit 1; }
python=$(awk -F'"' '$2 == "python" {print $4}' "$PREPARATION/PREPARED.json")
[[ $python == /* && -x $python ]] || { echo "prepared Python interpreter missing" >&2; exit 1; }
"$python" - "$PREPARATION/PREPARED.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get("schema") != 2:
    raise SystemExit("preparation schema is obsolete; create a new preparation with the current scripts")
PY
logs="$PREPARATION/build-logs"
mkdir -p "$logs"
phase=initializing
set_phase() {
  phase=$1
  printf 'build phase: %s (logs: %s)\n' "$phase" "$logs"
}
set_phase python_identity
failure_receipt="$logs/failure-$SLURM_JOB_ID.tsv"
[[ ! -e $failure_receipt ]] || { echo "build failure receipt already exists: $failure_receipt" >&2; exit 1; }
record_failure() {
  local status=$1 line=$2
  trap - ERR
  set +e
  umask 077
  {
    printf 'state\tBUILD_FAILED\n'
    printf 'semantic_state\tCONVERGING\n'
    printf 'slurm_job_id\t%s\n' "$SLURM_JOB_ID"
    printf 'phase\t%s\n' "$phase"
    printf 'line\t%s\n' "$line"
    printf 'exit_status\t%s\n' "$status"
    printf 'preparation\t%s\n' "$PREPARATION"
    printf 'recorded_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$failure_receipt.tmp"
  mv "$failure_receipt.tmp" "$failure_receipt"
  chmod 0444 "$failure_receipt"
  exit "$status"
}
trap 'status=$?; record_failure "$status" "$LINENO"' ERR
fail() {
  echo "$1" >&2
  return "${2:-1}"
}
python_log="$logs/python-$SLURM_JOB_ID.json"
[[ ! -e $python_log ]] || fail "current Python log already exists: $python_log"
"$python" "$verify" python-identity > "$python_log"
build_python=$(cat "$python_log")
python_log_sha=$(sha256sum "$python_log" | awk '{print $1}')
chmod 0444 "$python_log"
set_phase prepared_verification
"$python" "$verify" prepared "$PREPARATION"

readarray -t fields < <("$python" "$helper" prepared-fields "$PREPARATION/PREPARED.json")
site=${fields[0]}
revision=${fields[1]}
environment=${fields[2]}
version=${fields[3]}
prepared_plan_key=${fields[4]}
prepared_python_compatibility=${fields[5]}
prepared_receipt_sha=$(sha256sum "$PREPARATION/PREPARED.json" | awk '{print $1}')
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
  set_phase existing_build_verification
  "$python" "$verify" build "$PREPARATION"
  echo "verified existing complete build: $version"
  exit 0
fi
lock_dir=$version/.build-writer
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "another build owns this version; owner follows:" >&2
  cat "$lock_dir/owner.txt" >&2 2>/dev/null || true
  fail "build writer lock is unavailable"
fi
completion_tmp=$version/.completion.$SLURM_JOB_ID
completion_marker=$version/.BUILD-COMPLETE.$SLURM_JOB_ID
cleanup() {
  [[ ! -d $completion_tmp ]] || rm -rf -- "$completion_tmp"
  if [[ ! -f $version/BUILD-COMPLETE.sha256 ]]; then
    rm -f -- "$version/run-env.sh" "$version/ldd.txt" "$version/INSTALL-MANIFEST.sha256" \
      "$version/INSTALL-LINKS.sha256" "$version/BUILD-RECEIPT.json" "$completion_marker"
  fi
  if [[ -f $lock_dir/owner.txt ]] && [[ $(cat "$lock_dir/owner.txt") == "$SLURM_JOB_ID" ]]; then
    rm -f -- "$lock_dir/owner.txt" || true
    rmdir "$lock_dir" || true
  fi
}
trap cleanup EXIT
printf '%s\n' "$SLURM_JOB_ID" > "$lock_dir/owner.txt"
if [[ ! -f $version/BUILD-COMPLETE.sha256 ]]; then
  rm -f -- "$version/run-env.sh" "$version/ldd.txt" "$version/INSTALL-MANIFEST.sha256" \
    "$version/INSTALL-LINKS.sha256" "$version/BUILD-RECEIPT.json"
fi

set_phase cache_setup
job_cache="$version/spack-cache/$SLURM_JOB_ID"
[[ ! -e $job_cache ]] || fail "build cache already exists: $job_cache"
mkdir -p "$(dirname "$job_cache")"
mkdir "$job_cache"
export SPACK_USER_CACHE_PATH="$job_cache"
bootstrap_root="$PREPARATION/spack-cache/bootstrap"
source_cache="$job_cache/source"
build_stage="$job_cache/stage"

spack=$(find "$PREPARATION/spack-unpack" -mindepth 3 -maxdepth 3 -path '*/bin/spack' -type f -print -quit)
[[ -x $spack ]] || fail "prepared Spack executable missing"
export SPACK_USER_CONFIG_PATH="$PREPARATION/spack-config"
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ftp_proxy=http://127.0.0.1:9
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy FTP_PROXY=$ftp_proxy NO_PROXY= no_proxy=
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_PROC_BIND=close OMP_PLACES=cores
mkdir -p "$logs" "$version/stages"
actual_user_cache=$("$python" "$spack" python -c 'import spack.paths; print(spack.paths.user_cache_path)')
actual_source_cache=$("$python" "$spack" python -c 'import spack.caches; print(spack.caches.fetch_cache_location())')
actual_bootstrap_root=$("$python" "$spack" bootstrap root)
actual_build_stages=$("$python" "$spack" python -c 'import json, spack.config, spack.stage; value = spack.config.get("config:build_stage"); value = [value] if isinstance(value, str) else value; print(json.dumps(spack.stage._resolve_paths(value), separators=(",", ":")))')
[[ $actual_user_cache == "$job_cache" ]] || fail "effective Spack user cache differs"
[[ $actual_source_cache == "$source_cache" ]] || fail "effective Spack source cache differs"
[[ $actual_bootstrap_root == "$bootstrap_root" ]] || fail "effective Spack bootstrap root differs"
[[ $actual_build_stages == "[\"$build_stage\"]" ]] || fail "effective Spack build stages differ"
printf 'spack_user_cache_path=%s\nsource_cache=%s\nbuild_stage=%s\nbootstrap_root=%s\n' \
  "$actual_user_cache" "$actual_source_cache" "$build_stage" "$actual_bootstrap_root" \
  > "$logs/cache-paths-$SLURM_JOB_ID.txt"
chmod 0444 "$logs/cache-paths-$SLURM_JOB_ID.txt"
set_phase offline_verification
"$python" "$spack" bootstrap status > "$logs/bootstrap-status.txt"
"$python" "$spack" -e "$environment" config get mirrors --json > "$logs/mirrors.json"
"$python" "$verify" mirrors "$logs/mirrors.json" "file://$PREPARATION/source-mirror"
"$python" "$spack" -e "$environment" fetch -D -m > "$logs/offline-fetch-proof.txt" 2>&1

stage() {
  local name=$1
  shift
  "$@" 2>&1 | tee "$logs/$name.log"
  "$python" "$spack" -e "$environment" find --format '{name} {version} {hash}' > "$logs/$name.verify.txt"
  sha256sum "$logs/$name.log" "$logs/$name.verify.txt" > "$version/stages/$name.complete"
}
set_phase compiler
stage compiler "$python" "$spack" -e "$environment" install --only-concrete --fail-fast -p 1 -j "$SLURM_CPUS_PER_TASK" 'gcc@=15.2.0'
set_phase dependencies
stage dependencies "$python" "$spack" -e "$environment" install --only-concrete --only dependencies --fail-fast -p 1 -j "$SLURM_CPUS_PER_TASK" 'local.palace@=0.18.0-scq'
set_phase palace
stage palace "$python" "$spack" -e "$environment" install --only-concrete --only package --fail-fast -p 1 -j "$SLURM_CPUS_PER_TASK" 'local.palace@=0.18.0-scq'

set_phase installed_locations
prefix=$("$python" "$spack" -e "$environment" location -i 'local.palace@=0.18.0-scq')
prefix=$(realpath "$prefix")
binary_path="$prefix/bin/palace-x86_64.bin"
[[ -x $binary_path ]] || fail "installed Palace executable not found in $prefix/bin"
"$python" "$verify" elf "$binary_path"
binary=$(realpath "$binary_path")
[[ $binary == "$prefix"/* ]] || fail "installed Palace executable resolves outside its prefix"
libceed_prefix=$("$python" "$spack" -e "$environment" location -i libceed)
jit="$libceed_prefix/include/ceed/jit-source"
[[ -d $jit ]] && find "$jit" -type f -print -quit | grep -q . || fail "libCEED JIT headers missing"
openmpi_prefix=$("$python" "$spack" -e "$environment" location -i openmpi)
prrte_prefix=$("$python" "$spack" -e "$environment" location -i prrte)
pmix_prefix=$("$python" "$spack" -e "$environment" location -i pmix)
gcc_prefix=$("$python" "$spack" -e "$environment" location -i 'gcc@=15.2.0')
mpirun=$(realpath "$openmpi_prefix/bin/mpirun")
[[ -x $mpirun && -x $gcc_prefix/bin/gcc ]]
set_phase runtime_artifacts
[[ ! -e $completion_tmp ]] || fail "completion staging path already exists"
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
! grep -q 'not found' "$completion_tmp/ldd.txt" || fail "unresolved shared library"
ldd_sha=$(sha256sum "$completion_tmp/ldd.txt" | awk '{print $1}')

set_phase install_manifest
find "$version/store" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$completion_tmp/INSTALL-MANIFEST.sha256"
find "$version/store" -type l -printf '%p -> %l\n' | LC_ALL=C sort | sha256sum > "$completion_tmp/INSTALL-LINKS.sha256"
binary_sha=$(sha256sum "$binary" | awk '{print $1}')
"$python" "$helper" write-build-record "$completion_tmp/BUILD-RECEIPT.json" \
  --field preparation_revision "$revision" --field site "$site" --field slurm_job_id "$SLURM_JOB_ID" \
  --field slurm_cpus_per_task "$SLURM_CPUS_PER_TASK" --field install_store "$version/store" \
  --field palace_prefix "$prefix" --field palace_binary "$binary" --field palace_binary_sha256 "$binary_sha" \
  --field ldd_sha256 "$ldd_sha" --field libceed_jit_source "$jit" --field libceed_prefix "$libceed_prefix" \
  --field openmpi_prefix "$openmpi_prefix" --field mpirun "$mpirun" --field prrte_prefix "$prrte_prefix" \
  --field pmix_prefix "$pmix_prefix" --field gcc_prefix "$gcc_prefix" --field spack_user_cache_path "$job_cache" \
  --field source_cache "$source_cache" --field build_stage "$build_stage" --field bootstrap_root "$bootstrap_root" \
  --field preparation "$PREPARATION" --field prepared_receipt_sha256 "$prepared_receipt_sha" \
  --field prepared_plan_key "$prepared_plan_key" --field prepared_python_compatibility "$prepared_python_compatibility" \
  --field build_python "$build_python" --field build_python_log "$python_log" --field build_python_log_sha256 "$python_log_sha"
set_phase staged_artifact_verification
"$python" "$helper" verify-staged "$completion_tmp/INSTALL-MANIFEST.sha256" \
  "$completion_tmp/INSTALL-LINKS.sha256" "$version/store"
set_phase publish_artifacts
for name in run-env.sh ldd.txt INSTALL-MANIFEST.sha256 INSTALL-LINKS.sha256 BUILD-RECEIPT.json; do
  [[ ! -e $version/$name ]] || fail "incomplete completion artifact already exists: $version/$name"
  mv "$completion_tmp/$name" "$version/$name"
done
chmod 0444 "$version/run-env.sh" "$version/ldd.txt" "$version/INSTALL-MANIFEST.sha256" "$version/INSTALL-LINKS.sha256" "$version/BUILD-RECEIPT.json"
set_phase final_artifact_verification
"$python" "$verify" artifacts "$PREPARATION"
set_phase completion_publication
[[ ! -e $completion_marker ]]
sha256sum "$version/BUILD-RECEIPT.json" > "$completion_marker"
chmod 0444 "$completion_marker"
rmdir "$completion_tmp"
mv "$completion_marker" "$version/BUILD-COMPLETE.sha256"
