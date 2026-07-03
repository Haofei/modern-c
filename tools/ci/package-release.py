#!/usr/bin/env python3
"""Build and package mcc release artifacts."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time
from dataclasses import dataclass


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_TARGETS = ("x86_64-linux-musl", "aarch64-linux-musl")
REQUIRED_DOCS = (
    "README.md",
    "LICENSE",
    "SECURITY.md",
    "STABILITY.md",
    "CHANGELOG.md",
    "THIRD-PARTY-LICENSES.md",
)
REQUIRED_PACKAGE_PATHS = (
    "bin/mcc",
    "std/",
    "tools/toolchain/mcc-cc.sh",
    "tools/toolchain/mcc-llvm-cc.sh",
    *REQUIRED_DOCS,
)
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]*$")


@dataclass(frozen=True)
class PackageResult:
    target: str
    artifact_name: str
    artifact_path: pathlib.Path
    sha256: str
    size: int
    included_paths: tuple[str, ...]


def fail(message: str) -> None:
    print(f"package-release: {message}", file=sys.stderr)
    sys.exit(1)


def run(argv: list[str]) -> None:
    print("+ " + " ".join(argv), flush=True)
    subprocess.run(argv, cwd=ROOT, check=True)


def git_output(args: list[str], default: str = "") -> str:
    try:
        return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return default


def default_commit() -> str:
    commit = git_output(["rev-parse", "HEAD"])
    return commit or "unknown"


def default_source_epoch(commit: str) -> int:
    raw = os.environ.get("SOURCE_DATE_EPOCH")
    if raw:
        try:
            return int(raw)
        except ValueError:
            fail(f"SOURCE_DATE_EPOCH must be an integer, got {raw!r}")
    if commit != "unknown":
        raw = git_output(["show", "-s", "--format=%ct", commit])
        if raw:
            return int(raw)
    return 0


def iso_from_epoch(epoch: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def validate_version(version: str) -> None:
    if version.startswith("v"):
        fail("version must not include a leading 'v'; strip release tag prefixes first")
    if not VERSION_RE.fullmatch(version):
        fail(f"version contains unsupported characters: {version!r}")


def require_tree() -> None:
    missing: list[str] = []
    for path in REQUIRED_DOCS:
        if not (ROOT / path).is_file():
            missing.append(path)
    if not (ROOT / "std").is_dir():
        missing.append("std/")
    for path in ("tools/toolchain/mcc-cc.sh", "tools/toolchain/mcc-llvm-cc.sh"):
        if not (ROOT / path).is_file():
            missing.append(path)
    if missing:
        fail("missing required release payload paths: " + ", ".join(missing))


def build_target(target: str, version: str, prefix: pathlib.Path) -> None:
    argv = [
        "zig",
        "build",
        "install",
        "-Doptimize=ReleaseSafe",
        f"-Dversion={version}",
        "--prefix",
        str(prefix),
    ]
    if target != "native":
        argv.insert(3, f"-Dtarget={target}")
    run(argv)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_files(prefix: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    files: list[tuple[pathlib.Path, str]] = []
    mcc = prefix / "bin" / "mcc"
    if not mcc.is_file():
        fail(f"missing built compiler at {mcc}")
    files.append((mcc, "bin/mcc"))

    for source in sorted((ROOT / "std").rglob("*")):
        if source.is_file():
            files.append((source, source.relative_to(ROOT).as_posix()))

    for path in ("tools/toolchain/mcc-cc.sh", "tools/toolchain/mcc-llvm-cc.sh"):
        files.append((ROOT / path, path))
    for path in REQUIRED_DOCS:
        files.append((ROOT / path, path))
    return sorted(files, key=lambda item: item[1])


def tar_mode(source: pathlib.Path, dest: str) -> int:
    if dest == "bin/mcc" or os.access(source, os.X_OK):
        return 0o755
    return 0o644


def add_dir(tar: tarfile.TarFile, name: str, epoch: int) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = epoch
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    tar.addfile(info)


def add_file(tar: tarfile.TarFile, source: pathlib.Path, name: str, epoch: int) -> None:
    info = tarfile.TarInfo(name)
    info.size = source.stat().st_size
    info.mode = tar_mode(source, name.rsplit("/", 1)[-1] if name.startswith("mcc-") else name)
    info.mtime = epoch
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    with source.open("rb") as handle:
        tar.addfile(info, handle)


def make_tarball(
    *,
    target: str,
    version: str,
    prefix: pathlib.Path,
    out_dir: pathlib.Path,
    epoch: int,
) -> PackageResult:
    artifact_name = f"mcc-{version}-{target}.tar.gz"
    artifact_path = out_dir / artifact_name
    root_name = f"mcc-{version}-{target}"
    files = package_files(prefix)
    included_paths = tuple(dest for _, dest in files)

    dirs = {root_name}
    for _, dest in files:
        parts = pathlib.PurePosixPath(root_name, dest).parts
        for index in range(1, len(parts)):
            dirs.add("/".join(parts[:index]))

    out_dir.mkdir(parents=True, exist_ok=True)
    with artifact_path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as gzip_file:
            with tarfile.open(fileobj=gzip_file, mode="w", format=tarfile.PAX_FORMAT) as tar:
                for directory in sorted(dirs):
                    add_dir(tar, directory, epoch)
                for source, dest in files:
                    add_file(tar, source, f"{root_name}/{dest}", epoch)

    return PackageResult(
        target=target,
        artifact_name=artifact_name,
        artifact_path=artifact_path,
        sha256=sha256_file(artifact_path),
        size=artifact_path.stat().st_size,
        included_paths=included_paths,
    )


def write_checksums(out_dir: pathlib.Path, packages: list[PackageResult], metadata_paths: list[pathlib.Path]) -> pathlib.Path:
    path = out_dir / "SHA256SUMS"
    lines = [f"{package.sha256}  {package.artifact_name}\n" for package in sorted(packages, key=lambda p: p.artifact_name)]
    for metadata_path in sorted(metadata_paths, key=lambda p: p.name):
        lines.append(f"{sha256_file(metadata_path)}  {metadata_path.name}\n")
    path.write_text("".join(lines), encoding="utf-8")
    return path


def write_inventory(
    *,
    out_dir: pathlib.Path,
    version: str,
    commit: str,
    epoch: int,
    packages: list[PackageResult],
) -> pathlib.Path:
    path = out_dir / f"mcc-{version}-release-inventory.json"
    third_party = "THIRD-PARTY-LICENSES.md" if (ROOT / "THIRD-PARTY-LICENSES.md").is_file() else None
    payload = {
        "schema": "mcc-release-inventory-v1",
        "version": version,
        "commit": commit,
        "generated_at": iso_from_epoch(epoch),
        "source_date_epoch": epoch,
        "third_party_manifest": third_party,
        "artifacts": [
            {
                "name": package.artifact_name,
                "target": package.target,
                "sha256": package.sha256,
                "size": package.size,
                "included_paths": list(package.included_paths),
            }
            for package in sorted(packages, key=lambda p: p.artifact_name)
        ],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def write_sbom(
    *,
    out_dir: pathlib.Path,
    version: str,
    commit: str,
    epoch: int,
    packages: list[PackageResult],
) -> pathlib.Path:
    path = out_dir / f"mcc-{version}-sbom.cdx.json"
    payload = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": iso_from_epoch(epoch),
            "component": {
                "type": "application",
                "name": "mcc",
                "version": version,
                "properties": [{"name": "modern-c.commit", "value": commit}],
            },
        },
        "components": [
            {
                "type": "file",
                "name": package.artifact_name,
                "version": version,
                "hashes": [{"alg": "SHA-256", "content": package.sha256}],
                "properties": [{"name": "modern-c.target", "value": package.target}],
            }
            for package in sorted(packages, key=lambda p: p.artifact_name)
        ],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def release(args: argparse.Namespace) -> None:
    validate_version(args.version)
    require_tree()

    out_dir = pathlib.Path(args.out_dir)
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    build_root = pathlib.Path(args.build_root)
    if not build_root.is_absolute():
        build_root = ROOT / build_root
    commit = args.commit or default_commit()
    epoch = args.source_date_epoch if args.source_date_epoch is not None else default_source_epoch(commit)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    packages: list[PackageResult] = []
    for target in args.targets:
        prefix = build_root / target
        if not args.no_build:
            build_target(target, args.version, prefix)
        packages.append(
            make_tarball(
                target=target,
                version=args.version,
                prefix=prefix,
                out_dir=out_dir,
                epoch=epoch,
            )
        )

    inventory = write_inventory(out_dir=out_dir, version=args.version, commit=commit, epoch=epoch, packages=packages)
    sbom = write_sbom(out_dir=out_dir, version=args.version, commit=commit, epoch=epoch, packages=packages)
    checksums = write_checksums(out_dir, packages, [inventory, sbom])
    print(f"wrote {checksums.relative_to(ROOT)}")
    print(f"wrote {inventory.relative_to(ROOT)}")
    print(f"wrote {sbom.relative_to(ROOT)}")
    for package in packages:
        print(f"wrote {package.artifact_path.relative_to(ROOT)}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate-tree", help="check that required release payload paths exist")
    validate.set_defaults(func=lambda _args: require_tree())

    release_parser = sub.add_parser("release", help="build release tarballs, checksums, and inventory")
    release_parser.add_argument("--version", required=True, help="release version without a leading v")
    release_parser.add_argument("--commit", default="", help="source commit recorded in the inventory")
    release_parser.add_argument("--out-dir", default="zig-out/release", help="directory for release outputs")
    release_parser.add_argument("--build-root", default="zig-out/release-build", help="directory for Zig install prefixes")
    release_parser.add_argument("--targets", nargs="+", default=list(DEFAULT_TARGETS), help="Zig targets to build and package")
    release_parser.add_argument("--source-date-epoch", type=int, default=None, help="timestamp used for tar metadata and inventory")
    release_parser.add_argument("--no-build", action="store_true", help="package existing install prefixes under --build-root")
    release_parser.set_defaults(func=release)

    return parser.parse_args(argv)


def main(argv: list[str]) -> None:
    args = parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main(sys.argv[1:])
