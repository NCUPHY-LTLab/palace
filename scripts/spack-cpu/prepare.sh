#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

usage() {
  echo "Usage: CASE_BUNDLE=/absolute/archive $0 {f1|ltlab} [root]" >&2
  echo "Required: SLURM_PREFIX and SLURM_SPACK_SPEC (slurm@=YY-MM-PATCH-RELEASE)." >&2
  exit 2
}
[[ $# -ge 1 && $# -le 2 ]] || usage
site=$1
[[ $site == f1 || $site == ltlab ]] || usage
root=${2:-${PALACE_SPACK_ROOT:-$HOME/opt/palace-spack}}
[[ $root == /* ]] || { echo "installation root must be absolute" >&2; exit 2; }
: "${CASE_BUNDLE:?set CASE_BUNDLE to the absolute owner-provided archive}"
: "${SLURM_PREFIX:?set SLURM_PREFIX to the external site Slurm prefix}"
: "${SLURM_SPACK_SPEC:?set SLURM_SPACK_SPEC to the exact external Spack Slurm spec}"
[[ $CASE_BUNDLE == /* && -f $CASE_BUNDLE ]] || { echo "CASE_BUNDLE must be an existing absolute file" >&2; exit 2; }
[[ $SLURM_PREFIX == /* && -d $SLURM_PREFIX ]] || { echo "SLURM_PREFIX must be an existing absolute directory" >&2; exit 2; }
for path in "$root" "$CASE_BUNDLE" "$SLURM_PREFIX"; do
  [[ $path =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported path characters: $path" >&2; exit 2; }
done
[[ $SLURM_SPACK_SPEC =~ ^slurm@=[0-9]+-[0-9]{2}-[0-9]+-[0-9]+$ ]] || { echo "unsupported SLURM_SPACK_SPEC" >&2; exit 2; }
jobs=${SPACK_DOWNLOAD_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "SPACK_DOWNLOAD_JOBS must be positive" >&2; exit 2; }

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
readarray -t python_fields < <("$python" - "$python_identity" <<'PY'
import json, sys
record = json.loads(sys.argv[1])
print(record["version"])
print(record["executable_sha256"])
PY
)
python_version=${python_fields[0]}
python_sha=${python_fields[1]}
actual_gcc=$(gcc -dumpfullversion)
[[ $actual_gcc == "$expected_gcc" ]] || { echo "expected GCC $expected_gcc, found $actual_gcc" >&2; exit 1; }
for tool in gcc g++ gfortran git curl sha256sum srun; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }; done
slurm_command=$(realpath "$(command -v srun)")
slurm_prefix=$(realpath "$SLURM_PREFIX")
[[ $slurm_command == "$slurm_prefix"/* ]] || { echo "srun is outside SLURM_PREFIX" >&2; exit 1; }
slurm_runtime=$(srun --version | head -1)
"$python" - "$SLURM_SPACK_SPEC" "$slurm_runtime" <<'PY'
import re, sys
match = re.match(r"^slurm@=([0-9]+)-([0-9]{2})-([0-9]+)-([0-9]+)$", sys.argv[1])
runtime = re.match(r"^slurm ([0-9]+)\.([0-9]+)\.([0-9]+)$", sys.argv[2])
if not match or not runtime or match.groups()[:3] != runtime.groups():
    raise SystemExit("declared Spack Slurm version does not map to srun --version")
PY

checkout=$(git -C "$script_dir" rev-parse --show-toplevel)
[[ $checkout =~ ^/[A-Za-z0-9._/@+=-]+$ ]] || { echo "unsupported checkout path characters" >&2; exit 2; }
[[ -z $(git -C "$checkout" status --porcelain) ]] || { echo "checkout must be clean" >&2; exit 1; }
revision=$(git -C "$checkout" rev-parse HEAD)
tree=$(git -C "$checkout" rev-parse HEAD^{tree})
workflow_tree=$(git -C "$checkout" rev-parse "$revision:scripts/spack-cpu")
recipe_blob=$(git -C "$checkout" rev-parse "$revision:spack_repo/local/packages/palace/package.py")
lock_blob=$(git -C "$checkout" rev-parse "$revision:scripts/spack-cpu/lock.json")
case_sha=$(sha256sum "$CASE_BUNDLE" | awk '{print $1}')
gcc_path=$(realpath "$(command -v gcc)")
gxx_path=$(realpath "$(command -v g++)")
gfortran_path=$(realpath "$(command -v gfortran)")
seed_gcc_prefix=$(realpath "$(dirname "$(dirname "$gcc_path")")")
[[ $gxx_path == "$seed_gcc_prefix"/* && $gfortran_path == "$seed_gcc_prefix"/* ]] || { echo "seed GCC compilers do not share one prefix" >&2; exit 1; }
gcc_sha=$(sha256sum "$gcc_path" | awk '{print $1}')
gxx_sha=$(sha256sum "$gxx_path" | awk '{print $1}')
gfortran_sha=$(sha256sum "$gfortran_path" | awk '{print $1}')
slurm_sha=$(sha256sum "$slurm_command" | awk '{print $1}')
plan_key=$("$python" - "$site" "$root" "$revision" "$tree" "$workflow_tree" "$recipe_blob" "$lock_blob" "$actual_gcc" "$gcc_path" "$gcc_sha" "$gxx_path" "$gxx_sha" "$gfortran_path" "$gfortran_sha" "$python" "$python_version" "$python_sha" "$python_identity" "$SLURM_SPACK_SPEC" "$slurm_prefix" "$slurm_command" "$slurm_sha" "$slurm_runtime" "$case_sha" <<'PY'
import hashlib, json, sys
keys = ("site", "root", "revision", "tree", "workflow_tree", "recipe_blob", "lock_blob", "gcc_version", "gcc", "gcc_sha256", "gxx", "gxx_sha256", "gfortran", "gfortran_sha256", "python", "python_version", "python_sha256", "python_identity", "slurm_spec", "slurm_prefix", "srun", "srun_sha256", "srun_version", "case_sha256")
payload = dict(zip(keys, sys.argv[1:]))
print(hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
PY
)
id="palace-0.18.0-${revision:0:12}-${site}-${plan_key:0:12}"
prep="$root/preparations/$id"
version="$root/versions/$id"
cache="$root/cache"
logs="$root/logs/$id"

if [[ -e $prep || -e $version ]]; then
  [[ -f $prep/source/palace/scripts/spack-cpu/verify.py ]] || { echo "existing preparation is incomplete: $prep" >&2; exit 1; }
  "$python" "$prep/source/palace/scripts/spack-cpu/verify.py" prepared "$prep" --plan-key "$plan_key"
  echo "verified existing preparation: $prep"
  exit 0
fi
mkdir -p "$cache/downloads" "$root/preparations" "$root/versions" "$logs"
mkdir "$prep" "$version"
work=$prep
trap 'if [[ -d ${work:-} ]]; then echo "incomplete preparation retained: $work" >&2; fi' EXIT

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

"$python" - "$lock" <<'PY' > "$work/downloads.tsv"
import json, sys
lock = json.load(open(sys.argv[1]))
for item in [lock["spack"], lock["packages"]] + lock["snapshots"]:
    name = item.get("archive", item.get("package", "spack") + "-" + item.get("commit", "") + ".tar.gz")
    print("\t".join((name, item["url"], item["sha256"])))
PY
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
done < <("$python" - "$lock" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1]))["package_patches"]:
    print(item["file"] + "\t" + item["sha256"])
PY
)

"$python" "$frozen_scripts/render.py" --checkout "$work/source/palace" --packages "$packages_root" --cache "$cache/downloads" --source-archive "$source_archive" --source-sha256 "$source_sha" --destination "$work/generated" --install-root "$version/store" --site "$site" --slurm-prefix "$slurm_prefix" --slurm-spec "$SLURM_SPACK_SPEC"
"$python" "$frozen_scripts/prepare_cases.py" --source "$work/source/palace" --xmon-archive "$CASE_BUNDLE" --destination "$work/cases" --python "$python"

export SPACK_USER_CONFIG_PATH="$work/spack-config"
export SPACK_USER_CACHE_PATH="$work/spack-cache"
mkdir -p "$SPACK_USER_CONFIG_PATH" "$SPACK_USER_CACHE_PATH"
cat > "$SPACK_USER_CONFIG_PATH/repos.yaml" <<EOF
repos:
  local: $work/generated/spack_repo/local
  builtin: $packages_root/repos/spack_repo/builtin
EOF
cat > "$SPACK_USER_CONFIG_PATH/config.yaml" <<'EOF'
config:
  source_cache: '$user_cache_path/source'
  build_stage::
  - '$user_cache_path/stage'
EOF
cat > "$SPACK_USER_CONFIG_PATH/bootstrap.yaml" <<EOF
bootstrap:
  root: $work/spack-cache/bootstrap
  trusted:
    spack-install: false
EOF
spack="$spack_root/bin/spack"
"$python" "$spack" bootstrap disable spack-install
"$python" "$spack" bootstrap now
"$python" "$spack" bootstrap status > "$work/bootstrap-status.txt"
"$python" "$spack" -e "$work/generated/environment" compiler find --scope "env:$work/generated/environment"
"$python" "$spack" -e "$work/generated/environment" concretize --fresh --force
"$python" "$spack" -e "$work/generated/environment" spec -Il > "$work/concrete-spec.txt"
"$python" - "$work/generated/environment/spack.lock" "$SLURM_SPACK_SPEC" "$slurm_prefix" "$actual_gcc" "$seed_gcc_prefix" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
expected_version = sys.argv[2].split("@=", 1)[1]
matches = [x for x in lock["concrete_specs"].values() if x.get("name") == "slurm"]
if len(matches) != 1 or matches[0].get("version") != expected_version:
    raise SystemExit("concrete lock has wrong Slurm version")
if matches[0].get("external", {}).get("path") != sys.argv[3]:
    raise SystemExit("concrete lock did not retain external Slurm prefix")
gcc = [x for x in lock["concrete_specs"].values() if x.get("name") == "gcc" and x.get("version") == sys.argv[4] and "external" in x]
if len(gcc) != 1 or gcc[0]["external"].get("path") != sys.argv[5]:
    raise SystemExit("concrete lock did not retain the exact external seed GCC")
PY
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
"$python" - "$version/OWNER.json" "$plan_key" "$revision" "$tree" "$site" "$prep" <<'PY'
import json, sys
keys = ("plan_key", "preparation_revision", "preparation_tree", "site", "preparation")
record = {"schema": 1}
record.update(dict(zip(keys, sys.argv[2:])))
open(sys.argv[1], "w").write(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
owner_sha=$(sha256sum "$version/OWNER.json" | awk '{print $1}')
"$python" - "$work/PREPARED.json" "$plan_key" "$site" "$revision" "$tree" "$workflow_tree" "$recipe_blob" "$lock_blob" "$solver_manifest" "$source_sha" "$spack_commit" "$packages_commit" "$SLURM_SPACK_SPEC" "$slurm_prefix" "$slurm_command" "$slurm_sha" "$slurm_runtime" "$actual_gcc" "$gcc_path" "$gcc_sha" "$gxx_path" "$gxx_sha" "$gfortran_path" "$gfortran_sha" "$python" "$python_version" "$python_sha" "$python_identity" "$case_sha" "$work/generated/environment" "$version" "$work/spack-cache/bootstrap" "$owner_sha" <<'PY'
import json, sys
keys = ("plan_key", "site", "preparation_revision", "preparation_tree", "workflow_tree", "recipe_blob", "lock_blob", "solver_content_manifest_sha256", "source_archive_sha256", "spack_commit", "packages_commit", "slurm_spec", "slurm_prefix", "srun", "srun_sha256", "srun_version", "seed_gcc_version", "gcc", "gcc_sha256", "gxx", "gxx_sha256", "gfortran", "gfortran_sha256", "python", "python_version", "python_sha256", "python_identity", "case_archive_sha256", "environment", "version_root", "bootstrap_root", "owner_sha256")
record = {"schema": 2, "state": "PREPARED", "semantic_state": "CONVERGING"}
record.update(dict(zip(keys, sys.argv[2:])))
identity = json.loads(record.pop("python_identity"))
record["python_compatibility"] = {
    key: identity[key]
    for key in ("implementation", "major_minor", "soabi", "ext_suffix", "machine", "exec_prefix")
}
open(sys.argv[1], "w").write(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
find "$work" -type f ! -name PREPARED-MANIFEST.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$work/PREPARED-MANIFEST.sha256"
"$python" "$frozen_scripts/verify.py" prepared "$work" --plan-key "$plan_key"
work=
echo "prepared: $prep"
echo "build target: $version"
