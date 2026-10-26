#!/usr/bin/env python3
"""Render the machine-local Palace CPU Spack repository and environment."""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def add_version(recipe, declaration):
    text = recipe.read_text()
    anchor = '    version("develop", branch='
    offset = text.find(anchor)
    if offset < 0:
        offset = text.find("    version(")
    if offset < 0:
        raise RuntimeError("no version declaration in {0}".format(recipe))
    text = text[:offset] + declaration + "\n" + text[offset:]
    recipe.write_text(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--source-archive", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--install-root", type=Path, required=True)
    parser.add_argument("--site", choices=("f1", "ltlab"), required=True)
    parser.add_argument("--slurm-prefix", type=Path, required=True)
    parser.add_argument("--slurm-spec", required=True)
    args = parser.parse_args()

    if not args.slurm_prefix.is_absolute() or not args.slurm_prefix.is_dir():
        raise RuntimeError("Slurm prefix must be an existing absolute directory")
    if not re.match(r"^slurm@=[0-9]+-[0-9]{2}-[0-9]+-[0-9]+$", args.slurm_spec):
        raise RuntimeError("unsupported Slurm external spec")

    lock = json.loads((args.checkout / "scripts/spack-cpu/lock.json").read_text())
    if sha256(args.source_archive) != args.source_sha256:
        raise RuntimeError("Palace source archive checksum mismatch")

    destination = args.destination.resolve()
    if destination.exists():
        raise RuntimeError("generated destination already exists: {0}".format(destination))
    repository = destination / "spack_repo/local"
    repository.parent.mkdir(parents=True)
    shutil.copytree(args.checkout / "spack_repo/local", repository)

    palace_recipe = repository / "packages/palace/package.py"
    add_version(
        palace_recipe,
        '    version("0.19.0-scq", url="file://{0}", sha256="{1}")'.format(
            args.source_archive.resolve(), args.source_sha256
        ),
    )

    package_root = args.packages / "repos/spack_repo/builtin/packages"
    for item in lock["snapshots"]:
        archive = args.cache / item.get(
            "archive", item["package"] + "-" + item["commit"] + ".tar.gz"
        )
        if not archive.is_file() or sha256(archive) != item["sha256"]:
            raise RuntimeError("missing or corrupt source snapshot: {0}".format(archive))
        source = package_root / item["directory"]
        target = repository / "packages" / item["directory"]
        shutil.copytree(source, target)
        add_version(
            target / "package.py",
            '    version("{0}", url="file://{1}", sha256="{2}")'.format(
                item["version"], archive.resolve(), item["sha256"]
            ),
        )

    # Keep the existing machine-local provider recipes. The fixed upstream CI packages
    # snapshot is patched before this script runs.
    for directory in ("metis", "parmetis", "openblas"):
        shutil.copytree(package_root / directory, repository / "packages" / directory)

    environment = destination / "environment"
    environment.mkdir()
    install_root = args.install_root.resolve()
    yaml = """spack:
  specs:
  - group: compiler
    specs:
    - gcc@=15.2.0 languages='c,c++,fortran' ~nvptx
  - group: palace
    needs: [compiler]
    matrix:
    - [local.palace@=0.19.0-scq +shared +openmp +superlu-dist +mumps +slepc +arpack +sundials +gslib +libxsmm ~strumpack ~cuda ~rocm ~int64 build_type=Release cxxstd=20]
    - ["%c,cxx,fortran=gcc@15.2.0"]
  view: false
  concretizer:
    unify: true
    reuse: false
  config:
    install_tree:
      root: {install_root_yaml}
      padded_length: 256
  packages:
    all:
      target: [x86_64]
    zlib-api:
      require: "zlib@=1.3.2 +shared"
    slurm:
      externals:
      - spec: {slurm_spec_yaml}
        prefix: {slurm_prefix_yaml}
      buildable: false
    mpi:
      require: "openmpi@=5.0.10 +fortran ~internal-hwloc ~internal-libevent ~internal-pmix ~java ~memchecker ~openshmem ~rsh ~static schedulers=slurm fabrics=ucx,ofi"
    blas:
      require: "openblas@=0.3.34 threads=pthreads +locking ~ilp64"
    lapack:
      require: "openblas@=0.3.34 threads=pthreads +locking ~ilp64"
    scalapack:
      require: "netlib-scalapack@=2.2.3 +shared"
    mumps:
      require: "@=5.9.1 +mpi +double ~float ~complex ~int64 +metis +parmetis +shared +openmp"
    metis:
      require: "@=5.1.0 +petsc_patches +gkrand ~int64"
    parmetis:
      require: "@=4.0.3 +petsc_patches ~int64"
    superlu-dist:
      require: "@=9.3.0 ~openmp ~int64"
    petsc:
      require: "@=3.26.0 +mpi +double +complex ~int64 +openmp ~hdf5"
    slepc:
      require: "@=3.26.0 ~arpack"
    hypre:
      require: "@=3.2.0 ~int64 ~mixedint ~complex ~unified-memory +lapack +openmp"
    mfem:
      require: "@=4.10.0 +mpi +metis +lapack +openmp +threadsafe +superlu-dist +mumps +sundials +gslib +shared ~static"
    libceed:
      require: "@=1.0.0 +shared +openmp +libxsmm ~cuda ~rocm"
    libxsmm:
      require: "@=2.1.0 +shared blas=0"
""".format(
        install_root_yaml=json.dumps(str(install_root)),
        slurm_prefix_yaml=json.dumps(str(args.slurm_prefix.resolve())),
        slurm_spec_yaml=json.dumps(args.slurm_spec),
    )
    (environment / "spack.yaml").write_text(yaml)
    identity = {
        "schema": 1,
        "site": args.site,
        "slurm_prefix": str(args.slurm_prefix.resolve()),
        "slurm_spec": args.slurm_spec,
        "source_archive": str(args.source_archive.resolve()),
        "source_sha256": args.source_sha256,
        "lock_sha256": sha256(args.checkout / "scripts/spack-cpu/lock.json"),
        "repository": str(repository),
        "environment": str(environment),
    }
    (destination / "render-identity.json").write_text(
        json.dumps(identity, indent=2, sort_keys=True) + "\n"
    )


if __name__ == "__main__":
    main()
