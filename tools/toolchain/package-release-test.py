#!/usr/bin/env python3
"""Smoke-test release packaging without building or publishing a release."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
VERSION = "0.7.0-test"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
SOURCE_DATE_EPOCH = 1_700_000_000
TARGETS = ("native", "x86_64-linux-musl")
REQUIRED_PREFIX_FILES = (
    "bin/mcc",
    "bin/mcc-real",
    "tools/toolchain/mcc-build.sh",
    "tools/toolchain/mcc-cc.sh",
    "tools/toolchain/mcc-llvm-cc.sh",
)
REQUIRED_ROOT_FILES = (
    "README.md",
    "LICENSE",
    "SECURITY.md",
    "STABILITY.md",
    "CHANGELOG.md",
    "THIRD-PARTY-LICENSES.md",
)
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")


def fail(message: str) -> None:
    print(f"FAIL: package-release-test - {message}")
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def std_files() -> tuple[str, ...]:
    files = tuple(sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "std").rglob("*") if path.is_file()))
    require(bool(files), "std/ must contain at least one file")
    return files


def expected_payload_paths() -> tuple[str, ...]:
    return tuple(sorted((*REQUIRED_PREFIX_FILES, *REQUIRED_ROOT_FILES, *std_files())))


def write_executable(path: pathlib.Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def create_fake_prefixes(build_root: pathlib.Path) -> None:
    for target in TARGETS:
        prefix = build_root / target
        write_executable(prefix / "bin" / "mcc", f"#!/bin/sh\nprintf '%s\\n' fake-mcc-{target}\n")
        write_executable(prefix / "bin" / "mcc-real", f"#!/bin/sh\nprintf '%s\\n' fake-mcc-real-{target}\n")
        write_executable(prefix / "tools/toolchain/mcc-build.sh", "#!/bin/sh\nexit 0\n")
        write_executable(prefix / "tools/toolchain/mcc-cc.sh", "#!/bin/sh\nexit 0\n")
        write_executable(prefix / "tools/toolchain/mcc-llvm-cc.sh", "#!/bin/sh\nexit 0\n")


def run_packager(build_root: pathlib.Path, out_dir: pathlib.Path, version: str = VERSION) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "python3",
            "tools/ci/package-release.py",
            "release",
            "--no-build",
            "--version",
            version,
            "--commit",
            COMMIT,
            "--source-date-epoch",
            str(SOURCE_DATE_EPOCH),
            "--build-root",
            str(build_root),
            "--out-dir",
            str(out_dir),
            "--targets",
            *TARGETS,
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def require_success(result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode != 0:
        fail("packager failed\n" f"stdout:\n{result.stdout}\n" f"stderr:\n{result.stderr}")


def read_checksums(out_dir: pathlib.Path) -> dict[str, str]:
    path = out_dir / "SHA256SUMS"
    require(path.is_file(), "SHA256SUMS was not written")
    checksums: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        parts = line.split("  ", 1)
        require(len(parts) == 2, f"SHA256SUMS:{line_number} is not '<digest>  <file>'")
        digest, subject = parts
        require(HEX64_RE.fullmatch(digest) is not None, f"SHA256SUMS:{line_number} digest is not lowercase SHA-256 hex")
        require(subject and "/" not in subject, f"SHA256SUMS:{line_number} subject must be a basename: {subject!r}")
        require(subject not in checksums, f"SHA256SUMS has duplicate subject {subject!r}")
        subject_path = out_dir / subject
        require(subject_path.is_file(), f"SHA256SUMS subject does not exist: {subject!r}")
        actual = sha256_file(subject_path)
        require(actual == digest, f"SHA256SUMS digest mismatch for {subject!r}")
        checksums[subject] = digest
    return checksums


def inventory_path(out_dir: pathlib.Path) -> pathlib.Path:
    return out_dir / f"mcc-{VERSION}-release-inventory.json"


def sbom_path(out_dir: pathlib.Path) -> pathlib.Path:
    return out_dir / f"mcc-{VERSION}-sbom.cdx.json"


def tarball_name(target: str) -> str:
    return f"mcc-{VERSION}-{target}.tar.gz"


def require_checksums(out_dir: pathlib.Path) -> None:
    checksums = read_checksums(out_dir)
    expected_subjects = {
        *(tarball_name(target) for target in TARGETS),
        inventory_path(out_dir).name,
        sbom_path(out_dir).name,
    }
    require(set(checksums) == expected_subjects, f"SHA256SUMS subjects are {sorted(checksums)}, want {sorted(expected_subjects)}")


def load_json(path: pathlib.Path):
    require(path.is_file(), f"missing JSON output {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def require_inventory(out_dir: pathlib.Path) -> None:
    payload = load_json(inventory_path(out_dir))
    require(payload.get("schema") == "mcc-release-inventory-v1", "inventory schema mismatch")
    require(payload.get("version") == VERSION, "inventory version mismatch")
    require(payload.get("commit") == COMMIT, "inventory commit mismatch")
    require(payload.get("source_date_epoch") == SOURCE_DATE_EPOCH, "inventory source_date_epoch mismatch")
    require(payload.get("third_party_manifest") == "THIRD-PARTY-LICENSES.md", "inventory third_party_manifest mismatch")

    artifacts = payload.get("artifacts")
    require(isinstance(artifacts, list), "inventory artifacts must be a list")
    require(len(artifacts) == len(TARGETS), f"inventory must list {len(TARGETS)} artifacts")

    by_target: dict[str, dict[str, object]] = {}
    expected_paths = set(expected_payload_paths())
    for artifact in artifacts:
        require(isinstance(artifact, dict), "inventory artifact must be an object")
        target = artifact.get("target")
        require(isinstance(target, str), "inventory artifact target must be a string")
        require(target in TARGETS, f"inventory has unexpected target {target!r}")
        require(target not in by_target, f"inventory has duplicate target {target!r}")
        by_target[target] = artifact

        tarball = out_dir / tarball_name(target)
        require(artifact.get("name") == tarball.name, f"inventory artifact name mismatch for {target}")
        require(artifact.get("sha256") == sha256_file(tarball), f"inventory sha256 mismatch for {target}")
        require(artifact.get("size") == tarball.stat().st_size, f"inventory size mismatch for {target}")

        included_paths = artifact.get("included_paths")
        require(isinstance(included_paths, list), f"inventory included_paths for {target} must be a list")
        included = set(included_paths)
        missing = sorted(expected_paths - included)
        require(not missing, f"inventory for {target} is missing payload paths: {missing}")
        require(any(path.startswith("std/") for path in included), f"inventory for {target} has no std paths")
    require(set(by_target) == set(TARGETS), "inventory target set mismatch")


def properties_dict(component: dict[str, object]) -> dict[str, str]:
    properties = component.get("properties", [])
    require(isinstance(properties, list), "SBOM properties must be a list")
    out: dict[str, str] = {}
    for item in properties:
        require(isinstance(item, dict), "SBOM property must be an object")
        name = item.get("name")
        value = item.get("value")
        require(isinstance(name, str) and isinstance(value, str), "SBOM property name/value must be strings")
        out[name] = value
    return out


def require_sbom(out_dir: pathlib.Path) -> None:
    payload = load_json(sbom_path(out_dir))
    require(payload.get("bomFormat") == "CycloneDX", "SBOM bomFormat mismatch")
    require(payload.get("specVersion") == "1.5", "SBOM specVersion mismatch")

    metadata = payload.get("metadata")
    require(isinstance(metadata, dict), "SBOM metadata must be an object")
    component = metadata.get("component")
    require(isinstance(component, dict), "SBOM metadata component must be an object")
    require(component.get("type") == "application", "SBOM metadata component type mismatch")
    require(component.get("name") == "mcc", "SBOM metadata component name mismatch")
    require(component.get("version") == VERSION, "SBOM metadata component version mismatch")
    require(properties_dict(component).get("modern-c.commit") == COMMIT, "SBOM metadata component commit mismatch")

    components = payload.get("components")
    require(isinstance(components, list), "SBOM components must be a list")
    require(len(components) == len(TARGETS), "SBOM must list one component per tarball")
    by_name: dict[str, dict[str, object]] = {}
    for component in components:
        require(isinstance(component, dict), "SBOM component must be an object")
        name = component.get("name")
        require(isinstance(name, str), "SBOM component name must be a string")
        require(name not in by_name, f"SBOM has duplicate component {name!r}")
        by_name[name] = component
        require(component.get("type") == "file", f"SBOM component {name} type mismatch")
        require(component.get("version") == VERSION, f"SBOM component {name} version mismatch")
        hashes = component.get("hashes")
        require(isinstance(hashes, list) and len(hashes) == 1, f"SBOM component {name} must have one hash")
        digest = hashes[0]
        require(isinstance(digest, dict), f"SBOM component {name} hash must be an object")
        require(digest.get("alg") == "SHA-256", f"SBOM component {name} hash alg mismatch")
        require(digest.get("content") == sha256_file(out_dir / name), f"SBOM component {name} hash content mismatch")
        target = properties_dict(component).get("modern-c.target")
        require(name == tarball_name(target or ""), f"SBOM component {name} target property mismatch")
    require(set(by_name) == {tarball_name(target) for target in TARGETS}, "SBOM component set mismatch")


def stripped_tar_paths(members: list[tarfile.TarInfo], root_name: str) -> set[str]:
    prefix = root_name + "/"
    paths: set[str] = set()
    for member in members:
        if member.name == root_name:
            continue
        require(member.name.startswith(prefix), f"tar member is outside root: {member.name!r}")
        paths.add(member.name[len(prefix) :])
    return paths


def require_tarball(out_dir: pathlib.Path, target: str) -> None:
    path = out_dir / tarball_name(target)
    root_name = f"mcc-{VERSION}-{target}"
    with tarfile.open(path, "r:gz") as tar:
        members = tar.getmembers()

    require(bool(members), f"{path.name} has no members")
    roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members if pathlib.PurePosixPath(member.name).parts}
    require(roots == {root_name}, f"{path.name} must have exactly one root directory, got {sorted(roots)}")
    root_members = [member for member in members if member.name == root_name and member.isdir()]
    require(len(root_members) == 1, f"{path.name} must contain one root directory entry")

    for member in members:
        require(member.mtime == SOURCE_DATE_EPOCH, f"{path.name}:{member.name} mtime is not deterministic")
        require(member.uid == 0 and member.gid == 0, f"{path.name}:{member.name} uid/gid is not root")
        require(member.uname == "root" and member.gname == "root", f"{path.name}:{member.name} uname/gname is not root")

    paths = stripped_tar_paths(members, root_name)
    missing = sorted(set(expected_payload_paths()) - paths)
    require(not missing, f"{path.name} is missing payload paths: {missing}")
    require("std" in paths, f"{path.name} is missing std directory")
    require(any(path.startswith("std/") for path in paths), f"{path.name} has no std file")

    by_name = {member.name: member for member in members}
    for executable in REQUIRED_PREFIX_FILES:
        member_name = f"{root_name}/{executable}"
        require(member_name in by_name, f"{path.name} missing executable {executable}")
        mode = stat.S_IMODE(by_name[member_name].mode)
        require(mode == 0o755, f"{path.name}:{executable} mode is {mode:o}, want 755")


def require_release_outputs(out_dir: pathlib.Path) -> None:
    require_checksums(out_dir)
    require_inventory(out_dir)
    require_sbom(out_dir)
    for target in TARGETS:
        require_tarball(out_dir, target)


def require_reproducible_outputs(first: pathlib.Path, second: pathlib.Path) -> None:
    deterministic_names = {
        "SHA256SUMS",
        inventory_path(first).name,
        sbom_path(first).name,
        *(tarball_name(target) for target in TARGETS),
    }
    for name in deterministic_names:
        require((first / name).read_bytes() == (second / name).read_bytes(), f"{name} is not byte-identical across packaging runs")


def require_leading_v_rejected(build_root: pathlib.Path, out_dir: pathlib.Path) -> None:
    result = run_packager(build_root, out_dir, version="v" + VERSION)
    require(result.returncode != 0, "packager accepted a leading-v version")
    combined = result.stdout + result.stderr
    require("leading 'v'" in combined, "leading-v rejection did not explain the version prefix")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mcc-package-release-test-") as raw_tmp:
        tmp = pathlib.Path(raw_tmp)
        build_root = tmp / "build-root"
        first_out = tmp / "out-1"
        second_out = tmp / "out-2"
        rejected_out = tmp / "out-rejected"

        create_fake_prefixes(build_root)

        first = run_packager(build_root, first_out)
        require_success(first)
        require_release_outputs(first_out)

        second = run_packager(build_root, second_out)
        require_success(second)
        require_release_outputs(second_out)
        require_reproducible_outputs(first_out, second_out)

        require_leading_v_rejected(build_root, rejected_out)

    print("PASS: package-release-test")


if __name__ == "__main__":
    main()
