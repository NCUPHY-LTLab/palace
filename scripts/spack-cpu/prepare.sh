#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

usage() {
  echo "Usage: [CASE_BUNDLE=/absolute/archive] $0 {f1|ltlab} [root]" >&2
  echo "Required: SLURM_PREFIX and SLURM_SPACK_SPEC (slurm@=YY-MM-PATCH-RELEASE)." >&2
  exit 2
}
set_phase() {
  phase=$1
  printf 'prepare phase: %s\n' "$phase"
}
sitecheck() {
  set_phase sitecheck
  if [[ $site == f1 ]]; then
    command -v module >/dev/null || { echo "F1 module command is unavailable" >&2; exit 1; }
    module purge
    module load gcc/11.2.0
    expected_gcc=11.2.0
    python=/usr/bin/python3.8
  else
    expected_gcc=11.4.0
    python=$(realpath "$(command -v python3)")
  fi
  [[ -x $python ]] || { echo "required Python interpreter missing: $python" >&2; exit 1; }
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  python_identity=$("$python" "$script_dir/verify.py" python-identity)
  readarray -t python_fields < <("$python" -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["version"]); print(r["executable_sha256"])' "$python_identity")
  python_version=${python_fields[0]}
  python_sha=${python_fields[1]}
  actual_gcc=$(gcc -dumpfullversion)
  [[ $actual_gcc == "$expected_gcc" ]] || { echo "expected GCC $expected_gcc, found $actual_gcc" >&2; exit 1; }
  for tool in gcc g++ gfortran git curl sha256sum srun; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
  done
  slurm_command=$(realpath "$(command -v srun)")
  slurm_prefix=$(realpath "$SLURM_PREFIX")
  [[ $slurm_command == "$slurm_prefix"/* ]] || { echo "srun is outside SLURM_PREFIX" >&2; exit 1; }
  slurm_runtime=$(srun --version | head -1)
  "$python" -c 'import re,sys; a=re.match(r"^slurm@=([0-9]+)-([0-9]{2})-([0-9]+)-([0-9]+)$",sys.argv[1]); b=re.match(r"^slurm ([0-9]+)\.([0-9]+)\.([0-9]+)$",sys.argv[2]); (a and b and a.groups()[:3]==b.groups()) or sys.exit("declared Spack Slurm version does not map to srun --version")' "$SLURM_SPACK_SPEC" "$slurm_runtime"

  checkout=$(git -C "$script_dir" rev-parse --show-toplevel)
  [[ $checkout =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported checkout path characters" >&2; exit 2; }
  [[ -z $(git -C "$checkout" status --porcelain) ]] || { echo "checkout must be clean" >&2; exit 1; }
  revision=$(git -C "$checkout" rev-parse HEAD)
  tree=$(git -C "$checkout" rev-parse HEAD^{tree})
  workflow_tree=$(git -C "$checkout" rev-parse "$revision:scripts/spack-cpu")
  recipe_blob=$(git -C "$checkout" rev-parse "$revision:spack_repo/local/packages/palace/package.py")
  lock_blob=$(git -C "$checkout" rev-parse "$revision:scripts/spack-cpu/lock.json")
  gcc_path=$(realpath "$(command -v gcc)")
  gxx_path=$(realpath "$(command -v g++)")
  gfortran_path=$(realpath "$(command -v gfortran)")
  seed_gcc_prefix=$(realpath "$(dirname "$(dirname "$gcc_path")")")
  [[ $gxx_path == "$seed_gcc_prefix"/* && $gfortran_path == "$seed_gcc_prefix"/* ]] || { echo "seed GCC compilers do not share one prefix" >&2; exit 1; }
  gcc_sha=$(sha256sum "$gcc_path" | awk '{print $1}')
  gxx_sha=$(sha256sum "$gxx_path" | awk '{print $1}')
  gfortran_sha=$(sha256sum "$gfortran_path" | awk '{print $1}')
  slurm_sha=$(sha256sum "$slurm_command" | awk '{print $1}')
  plan_key=$("$python" "$script_dir/prepare.py" plan-key \
    --field site "$site" --field root "$root" --field revision "$revision" --field tree "$tree" \
    --field workflow_tree "$workflow_tree" --field recipe_blob "$recipe_blob" --field lock_blob "$lock_blob" \
    --field gcc_version "$actual_gcc" --field gcc "$gcc_path" --field gcc_sha256 "$gcc_sha" \
    --field gxx "$gxx_path" --field gxx_sha256 "$gxx_sha" --field gfortran "$gfortran_path" \
    --field gfortran_sha256 "$gfortran_sha" --field python "$python" --field python_version "$python_version" \
    --field python_sha256 "$python_sha" --field python_identity "$python_identity" \
    --field slurm_spec "$SLURM_SPACK_SPEC" --field slurm_prefix "$slurm_prefix" --field srun "$slurm_command" \
    --field srun_sha256 "$slurm_sha" --field srun_version "$slurm_runtime" \
    --field case_mode "$case_mode" --field case_identity "$case_identity")
  id="palace-main-${revision:0:12}-${site}-${plan_key:0:12}"
  prep="$root/preparations/$id"
  version="$root/versions/$id"
  cache="$root/cache"
}
archive() {
  set_phase archive
  mkdir "$work/identity"
  source_archive="$work/identity/source-archive.tar.gz"
  git -C "$checkout" archive --format=tar.gz --prefix=palace/ "$revision" > "$source_archive"
  source_sha=$(sha256sum "$source_archive" | awk '{print $1}')
  git -C "$checkout" show "$revision:scripts/spack-cpu/archive.py" > "$work/archive.py"
  "$python" "$work/archive.py" "$source_archive" "$work/source"
  frozen_scripts="$work/source/palace/scripts/spack-cpu"
  lock="$frozen_scripts/lock.json"
  [[ $(git -C "$checkout" hash-object "$lock") == "$lock_blob" ]] || { echo "archived lock blob mismatch" >&2; exit 1; }
  solver_manifest=$(git -C "$checkout" ls-tree -r "$revision" | LC_ALL=C sort | awk '$4 !~ /^scripts\/spack-cpu\// && $4 !~ /^spack_repo\//' | sha256sum | awk '{print $1}')
  expected_solver_manifest=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["palace"]["solver_content_manifest_sha256"])' "$lock")
  [[ $solver_manifest == "$expected_solver_manifest" ]] || { echo "solver content differs from the reviewed native candidate" >&2; exit 1; }
}
download() {
  set_phase download
  "$python" "$frozen_scripts/prepare.py" downloads "$lock" > "$work/downloads.tsv"
  while IFS=$'\t' read -r name url expected; do
    target="$cache/downloads/$name"
    if [[ -f $target ]] && [[ $(sha256sum "$target" | awk '{print $1}') == "$expected" ]]; then continue; fi
    [[ ! -e $target ]] || { echo "cache checksum conflict: $target" >&2; exit 1; }
    part="$target.part.$$"
    curl --fail --location --proto '=https' --tlsv1.2 --output "$part" "$url"
    [[ $(sha256sum "$part" | awk '{print $1}') == "$expected" ]] || { echo "download checksum mismatch: $url" >&2; exit 1; }
    mv "$part" "$target"
  done < "$work/downloads.tsv"
  spack_commit=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["spack"]["commit"])' "$lock")
  packages_commit=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"]["commit"])' "$lock")
  packages_sha=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"]["sha256"])' "$lock")
  spack_sha=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["spack"]["sha256"])' "$lock")
  packages_archive=$(awk -F '\t' -v h="$packages_sha" '$3==h {print "'$cache'/downloads/" $1}' "$work/downloads.tsv")
  spack_archive=$(awk -F '\t' -v h="$spack_sha" '$3==h {print "'$cache'/downloads/" $1}' "$work/downloads.tsv")
  "$python" "$frozen_scripts/archive.py" "$spack_archive" "$work/spack-unpack"
  "$python" "$frozen_scripts/archive.py" "$packages_archive" "$work/packages-unpack"
  spack_root=$(find "$work/spack-unpack" -mindepth 1 -maxdepth 1 -type d -print -quit)
  packages_root=$(find "$work/packages-unpack" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [[ -n $spack_root && -n $packages_root ]]
  while IFS=$'\t' read -r patch_file patch_sha; do
    [[ $(sha256sum "$work/source/palace/$patch_file" | awk '{print $1}') == "$patch_sha" ]] || { echo "package patch checksum mismatch: $patch_file" >&2; exit 1; }
    git -C "$packages_root" apply --check "$work/source/palace/$patch_file"
    git -C "$packages_root" apply "$work/source/palace/$patch_file"
  done < <("$python" "$frozen_scripts/prepare.py" patches "$lock")
}
concretize() {
  set_phase concretize
  "$python" "$frozen_scripts/render.py" --checkout "$work/source/palace" --packages "$packages_root" --cache "$cache/downloads" --source-archive "$source_archive" --source-sha256 "$source_sha" --destination "$work/generated" --install-root "$version/store" --site "$site" --slurm-prefix "$slurm_prefix" --slurm-spec "$SLURM_SPACK_SPEC"
  case_args=(--source "$work/source/palace" --destination "$work/cases" --python "$python")
  [[ -z $case_bundle ]] || case_args+=(--xmon-archive "$case_bundle")
  "$python" "$frozen_scripts/prepare_cases.py" "${case_args[@]}"

  export SPACK_USER_CONFIG_PATH="$work/spack-config"
  export SPACK_USER_CACHE_PATH="$work/spack-cache"
  mkdir -p "$SPACK_USER_CONFIG_PATH" "$SPACK_USER_CACHE_PATH"
  cat > "$SPACK_USER_CONFIG_PATH/repos.yaml" <<CONFIG
repos:
  local: $work/generated/spack_repo/local
  builtin: $packages_root/repos/spack_repo/builtin
CONFIG
  cat > "$SPACK_USER_CONFIG_PATH/config.yaml" <<'CONFIG'
config:
  source_cache: '$user_cache_path/source'
  build_stage::
  - '$user_cache_path/stage'
CONFIG
  cat > "$SPACK_USER_CONFIG_PATH/bootstrap.yaml" <<CONFIG
bootstrap:
  root: $work/spack-cache/bootstrap
  trusted:
    spack-install: false
CONFIG
  spack="$spack_root/bin/spack"
  "$python" "$spack" bootstrap disable spack-install
  "$python" "$spack" bootstrap now
  "$python" "$spack" bootstrap status > "$work/bootstrap-status.txt"
  "$python" "$spack" -e "$work/generated/environment" compiler find --scope "env:$work/generated/environment"
  "$python" "$spack" -e "$work/generated/environment" concretize --fresh --force
  "$python" "$spack" -e "$work/generated/environment" spec -Il > "$work/concrete-spec.txt"
  "$python" "$frozen_scripts/prepare.py" validate-concrete "$work/generated/environment/spack.lock" "$SLURM_SPACK_SPEC" "$slurm_prefix" "$actual_gcc" "$seed_gcc_prefix"
}
offlineverify() {
  set_phase offlineverify
  "$python" "$spack" bootstrap mirror --binary-packages "$work/bootstrap-mirror"
  "$python" "$spack" bootstrap add --trust local-binaries "$work/bootstrap-mirror/metadata/binaries"
  "$python" "$spack" bootstrap disable github-actions-v2
  "$python" "$spack" bootstrap disable github-actions-v0.6
  "$python" "$spack" bootstrap disable spack-install
  "$python" "$spack" bootstrap status > "$work/offline-bootstrap-status.txt"
  "$python" "$spack" -e "$work/generated/environment" mirror create -a -j "$jobs" -d "$work/source-mirror" > "$work/source-mirror-create.txt"
  "$python" "$spack" -e "$work/generated/environment" config --scope "env:$work/generated/environment" add "mirrors::source-cache:'file://$work/source-mirror'"
  "$python" "$spack" -e "$work/generated/environment" config get mirrors --json > "$work/mirrors.json"
  "$python" "$frozen_scripts/verify.py" mirrors "$work/mirrors.json" "file://$work/source-mirror"
  export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ftp_proxy=http://127.0.0.1:9
  export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy FTP_PROXY=$ftp_proxy NO_PROXY= no_proxy=
  "$python" "$spack" -e "$work/generated/environment" fetch -D -m > "$work/offline-fetch-proof.txt"
  find "$work/source-mirror" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$work/source-mirror.sha256"
  find "$work/bootstrap-mirror" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$work/bootstrap-mirror.sha256"
  find "$work/source-mirror" -type l -printf '%p -> %l\n' | LC_ALL=C sort | sha256sum > "$work/source-mirror-links.sha256"
  find "$work/bootstrap-mirror" -type l -printf '%p -> %l\n' | LC_ALL=C sort | sha256sum > "$work/bootstrap-mirror-links.sha256"
}
receipt() {
  set_phase receipt
  {
    echo "gcc=$gcc_path"
    echo "gxx=$gxx_path"
    echo "gfortran=$gfortran_path"
    echo "gcc_version=$actual_gcc"
    echo "python=$python"
    echo "python_version=$python_version"
    echo "python_sha256=$python_sha"
    echo "python_identity=$python_identity"
    echo "srun=$slurm_command"
    echo "srun_sha256=$slurm_sha"
    echo "srun_version=$slurm_runtime"
    echo "slurm_external_spec=$SLURM_SPACK_SPEC"
    echo "slurm_external_prefix=$slurm_prefix"
  } > "$work/site-tools.txt"
  "$python" "$frozen_scripts/prepare.py" write-record owner "$version/OWNER.json" \
    --field plan_key "$plan_key" --field preparation_revision "$revision" --field preparation_tree "$tree" \
    --field site "$site" --field preparation "$prep"
  owner_sha=$(sha256sum "$version/OWNER.json" | awk '{print $1}')
  "$python" "$frozen_scripts/prepare.py" write-record prepared "$work/PREPARED.json" \
    --field plan_key "$plan_key" --field site "$site" --field preparation_revision "$revision" --field preparation_tree "$tree" \
    --field workflow_tree "$workflow_tree" --field recipe_blob "$recipe_blob" --field lock_blob "$lock_blob" \
    --field solver_content_manifest_sha256 "$solver_manifest" --field source_archive_sha256 "$source_sha" \
    --field spack_commit "$spack_commit" --field packages_commit "$packages_commit" \
    --field slurm_spec "$SLURM_SPACK_SPEC" --field slurm_prefix "$slurm_prefix" --field srun "$slurm_command" \
    --field srun_sha256 "$slurm_sha" --field srun_version "$slurm_runtime" --field seed_gcc_version "$actual_gcc" \
    --field gcc "$gcc_path" --field gcc_sha256 "$gcc_sha" --field gxx "$gxx_path" --field gxx_sha256 "$gxx_sha" \
    --field gfortran "$gfortran_path" --field gfortran_sha256 "$gfortran_sha" --field python "$python" \
    --field python_version "$python_version" --field python_sha256 "$python_sha" --field python_identity "$python_identity" \
    --field case_mode "$case_mode" --field case_identity "$case_identity" --field environment "$work/generated/environment" \
    --field version_root "$version" --field bootstrap_root "$work/spack-cache/bootstrap" --field owner_sha256 "$owner_sha"
  find "$work" -type f ! -name PREPARED-MANIFEST.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$work/PREPARED-MANIFEST.sha256"
  "$python" "$frozen_scripts/verify.py" prepared "$work" --plan-key "$plan_key"
}
jobgen() {
  set_phase jobgen
  local helper="$prep/source/palace/scripts/spack-cpu/prepare.py"
  local templates="$prep/source/palace/scripts/spack-cpu/templates"
  [[ -x $helper && -d $templates ]] || { echo "frozen job generator is missing" >&2; exit 1; }
  "$python" "$helper" jobs "$site" "$root" "$prep" "$templates"
}

[[ $# -ge 1 && $# -le 2 ]] || usage
site=$1
[[ $site == f1 || $site == ltlab ]] || usage
root=${2:-${PALACE_SPACK_ROOT:-$HOME/opt/palace-spack}}
[[ $root == /* ]] || { echo "installation root must be absolute" >&2; exit 2; }
: "${SLURM_PREFIX:?set SLURM_PREFIX to the external site Slurm prefix}"
: "${SLURM_SPACK_SPEC:?set SLURM_SPACK_SPEC to the exact external Spack Slurm spec}"
[[ $SLURM_PREFIX == /* && -d $SLURM_PREFIX ]] || { echo "SLURM_PREFIX must be an existing absolute directory" >&2; exit 2; }
case_bundle=${CASE_BUNDLE:-}
case_mode=public-only
case_identity=public-only
if [[ -n $case_bundle ]]; then
  [[ $case_bundle == /* && -f $case_bundle ]] || { echo "CASE_BUNDLE must be an existing absolute file" >&2; exit 2; }
  case_mode=xmon-c73772d
  case_identity=$(sha256sum "$case_bundle" | awk '{print $1}')
  [[ $case_identity == c73772d1e8f739c3f174eecffb4a2b8bc5df7b2c622aa7302d4ea3adc09cdff6 ]] || { echo "CASE_BUNDLE checksum is not the supported Xmon archive" >&2; exit 2; }
fi
checked_paths=("$root" "$SLURM_PREFIX")
[[ -z $case_bundle ]] || checked_paths+=("$case_bundle")
for path in "${checked_paths[@]}"; do
  [[ $path =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported path characters: $path" >&2; exit 2; }
done
[[ $SLURM_SPACK_SPEC =~ ^slurm@=[0-9]+-[0-9]{2}-[0-9]+-[0-9]+$ ]] || { echo "unsupported SLURM_SPACK_SPEC" >&2; exit 2; }
jobs=${SPACK_DOWNLOAD_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "SPACK_DOWNLOAD_JOBS must be positive" >&2; exit 2; }
phase=initializing
sitecheck

if [[ -e $prep || -e $version ]]; then
  [[ -f $prep/source/palace/scripts/spack-cpu/verify.py ]] || { echo "existing preparation is incomplete: $prep" >&2; exit 1; }
  "$python" "$prep/source/palace/scripts/spack-cpu/verify.py" prepared "$prep" --plan-key "$plan_key"
  jobgen
  echo "verified existing preparation: $prep"
  exit 0
fi
mkdir -p "$cache/downloads" "$root/preparations" "$root/versions"
mkdir "$prep" "$version"
work=$prep
trap 'if [[ -n ${work:-} && -d $work ]]; then echo "incomplete preparation retained at phase $phase: $work" >&2; fi' EXIT
archive
download
concretize
offlineverify
receipt
work=
jobgen
echo "prepared: $prep"
echo "build target: $version"
