#!/usr/bin/env python3
"""Static gate for release/version/process metadata."""

from __future__ import annotations

import pathlib
import re
import sys
import importlib.util


ROOT = pathlib.Path(__file__).resolve().parents[2]
EXPECTED_VERSION = "0.7.0-dev"
EXPECTED_UBUNTU_RUNNER = "ubuntu-24.04"
EXPECTED_LLVM_MAJOR = "18"
EXPECTED_ZIG_VERSION = "0.16.0"
EXPECTED_DOCKER_BASE_IMAGE = "ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90"
EXPECTED_ZIG_LINUX_SHA256 = (
    "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
    "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
)
EXPECTED_NIGHTLY_BENCH_TARGETS = (
    "mem-bench",
    "llvm-mem-bench",
    "uaccess-bench",
    "llvm-uaccess-bench",
    "sched-bench",
    "llvm-sched-bench",
    "heap-bench",
    "llvm-heap-bench",
    "ipc-bench",
    "llvm-ipc-bench",
)
EXPECTED_NIGHTLY_BENCH_METRICS = (
    "MEMCPY-CYCLES",
    "MEMSET-CYCLES",
    "UACCESS-TO-CYCLES",
    "UACCESS-FROM-CYCLES",
    "UACCESS-SMALL-CYCLES",
    "UACCESS-CYCLES",
    "SCHED-CYCLES",
    "HEAPFREE-CYCLES",
    "IPC-CYCLES",
)
EXPECTED_RELEASE_TARGETS = (
    "x86_64-linux-musl",
    "aarch64-linux-musl",
)
EXPECTED_RELEASE_PATHS = (
    "bin/mcc",
    "std/",
    "tools/toolchain/mcc-cc.sh",
    "tools/toolchain/mcc-llvm-cc.sh",
    "README.md",
    "LICENSE",
    "SECURITY.md",
    "STABILITY.md",
    "CHANGELOG.md",
    "THIRD-PARTY-LICENSES.md",
)
PINNED_ACTION_REF_RE = re.compile(r"^[0-9a-f]{40}$")
WORKFLOW_USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"\s#]+)")


def fail(message: str) -> None:
    print(f"FAIL: release-metadata-test - {message}")
    sys.exit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    return full.read_text(encoding="utf-8")


def require_contains(path: str, needle: str) -> None:
    if needle not in read(path):
        fail(f"{path} does not contain {needle!r}")


def require_workflow_actions_pinned() -> None:
    workflow_paths = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    if not workflow_paths:
        fail("missing .github/workflows/*.yml")
    for workflow_path in workflow_paths:
        relative = workflow_path.relative_to(ROOT)
        for line_number, line in enumerate(workflow_path.read_text(encoding="utf-8").splitlines(), 1):
            match = WORKFLOW_USES_RE.match(line)
            if not match:
                continue
            uses = match.group(1)
            if uses.startswith("./") or uses.startswith("../"):
                continue
            if "@" not in uses:
                fail(f"{relative}:{line_number} action {uses!r} must be pinned to a commit SHA")
            action, ref = uses.rsplit("@", 1)
            if not PINNED_ACTION_REF_RE.fullmatch(ref):
                fail(f"{relative}:{line_number} action {action!r} must use a 40-char commit SHA, not {ref!r}")


def load_python_module(path: str):
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    spec = importlib.util.spec_from_file_location("nightly_bench_static", full)
    if spec is None or spec.loader is None:
        fail(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def zon_field(text: str, name: str) -> str:
    match = re.search(rf"\.{re.escape(name)}\s*=\s*\"([^\"]+)\"", text)
    if not match:
        fail(f"build.zig.zon missing .{name}")
    return match.group(1)


def nightly_bench_expected_keys(module) -> set[tuple[str, str, str, str]]:
    keys: set[tuple[str, str, str, str]] = set()
    for bench in module.EXPECTED_BENCHES:
        for metric in bench.metrics:
            keys.add((bench.benchmark, bench.backend, bench.target, metric))
    return keys


def require_nightly_bench_metadata() -> None:
    workflow_path = ".github/workflows/nightly-bench.yml"
    runner_path = "tools/ci/nightly-bench.py"
    baseline_path = "tools/bench/nightly-baseline.tsv"

    workflow = read(workflow_path)
    for needle in (
        "schedule:",
        "workflow_dispatch:",
        f"runs-on: {EXPECTED_UBUNTU_RUNNER}",
        f'MC_LLVM_MAJOR: "{EXPECTED_LLVM_MAJOR}"',
        'MC_REQUIRE_TOOLS: "1"',
        "mlugg/setup-zig@v2",
        f"version: {EXPECTED_ZIG_VERSION}",
        f"clang-{EXPECTED_LLVM_MAJOR} lld-{EXPECTED_LLVM_MAJOR} llvm-{EXPECTED_LLVM_MAJOR}",
        "qemu-system-arm qemu-system-misc qemu-system-x86",
        f"/usr/lib/llvm-{EXPECTED_LLVM_MAJOR}/bin",
        "qemu-system-riscv64 --version",
        "zig build preflight",
        "python3 tools/ci/nightly-bench.py run",
        baseline_path,
        "zig-out/nightly-bench-results.tsv",
        "zig-out/nightly-bench-logs",
        "actions/upload-artifact@v4",
        "nightly-bench-results",
    ):
        require_contains(workflow_path, needle)
    if "ubuntu-latest" in workflow:
        fail(f"{workflow_path} must not use ubuntu-latest for compiler qualification")

    runner = read(runner_path)
    for needle in (
        "EXPECTED_BENCHES",
        "BASELINE_COLUMNS",
        "zig",
        "build",
        "install",
        "check-baseline",
        "tolerance_pct",
        "tolerance_abs",
        "max_allowed",
        "UACCESS-TO-CYCLES",
        "UACCESS-FROM-CYCLES",
        "UACCESS-CYCLES",
        "^SKIP:",
    ):
        require_contains(runner_path, needle)

    module = load_python_module(runner_path)
    targets = tuple(bench.target for bench in module.EXPECTED_BENCHES)
    for target in EXPECTED_NIGHTLY_BENCH_TARGETS:
        if target not in targets:
            fail(f"{runner_path} missing nightly benchmark target {target!r}")
    metrics = {metric for bench in module.EXPECTED_BENCHES for metric in bench.metrics}
    for metric in EXPECTED_NIGHTLY_BENCH_METRICS:
        if metric not in metrics:
            fail(f"{runner_path} missing nightly benchmark metric {metric!r}")

    baseline = read(baseline_path)
    expected_header = "benchmark\tbackend\ttarget\tmetric\tbaseline\ttolerance_pct\ttolerance_abs\n"
    if not baseline.startswith(expected_header):
        fail(f"{baseline_path} has the wrong TSV header")
    seen: set[tuple[str, str, str, str]] = set()
    for line in baseline.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) != 7:
            fail(f"{baseline_path} row has {len(parts)} fields, want 7: {line!r}")
        key = tuple(parts[:4])
        if key in seen:
            fail(f"{baseline_path} has duplicate row {key}")
        seen.add(key)
        for raw in parts[4:]:
            try:
                value = float(raw)
            except ValueError:
                fail(f"{baseline_path} has non-numeric tolerance/baseline value {raw!r}")
            if value < 0:
                fail(f"{baseline_path} has negative tolerance/baseline value {raw!r}")
        if float(parts[4]) <= 0:
            fail(f"{baseline_path} baseline must be > 0 for {key}")
    expected = nightly_bench_expected_keys(module)
    if seen != expected:
        fail(f"{baseline_path} rows do not match {runner_path} EXPECTED_BENCHES")


def require_release_artifact_metadata() -> None:
    workflow_path = ".github/workflows/release.yml"
    package_path = "tools/ci/package-release.py"
    workflow = read(workflow_path)
    packager = read(package_path)

    for needle in (
        "push:",
        "tags:",
        '"v*"',
        "workflow_dispatch:",
        "dry_run:",
        "runs-on: ubuntu-24.04",
        "actions/checkout@v4",
        "mlugg/setup-zig@v2",
        f"version: {EXPECTED_ZIG_VERSION}",
        "tools/ci/package-release.py release",
        "--version",
        "--commit \"$GITHUB_SHA\"",
        "sha256sum -c SHA256SUMS",
        "actions/upload-artifact@v4",
        "zig-out/release/*.tar.gz",
        "zig-out/release/SHA256SUMS",
        "zig-out/release/*inventory*.json",
        "zig-out/release/*sbom*.json",
        "startsWith(github.ref, 'refs/tags/v')",
        "gh release upload",
    ):
        require_contains(workflow_path, needle)
    if "ubuntu-latest" in workflow:
        fail(f"{workflow_path} must not use ubuntu-latest for release artifacts")
    if "softprops/action-gh-release" in workflow or "ncipollo/release-action" in workflow:
        fail(f"{workflow_path} must use gh release upload instead of a release action")

    for target in EXPECTED_RELEASE_TARGETS:
        require_contains(workflow_path, target)
        require_contains(package_path, target)
    for needle in (
        "zig",
        "build",
        "install",
        "-Doptimize=ReleaseSafe",
        "-Dversion=",
        "SHA256SUMS",
        "release-inventory.json",
        "mcc-release-inventory-v1",
        "sbom.cdx.json",
        "CycloneDX",
        "bomFormat",
        "sha256",
        "included_paths",
        "third_party_manifest",
        "source_date_epoch",
        "tarfile",
        "gzip.GzipFile",
    ):
        require_contains(package_path, needle)
    for path in EXPECTED_RELEASE_PATHS:
        require_contains(package_path, path)
    if "mcc build" in workflow or "mcc build" in packager:
        fail("release artifact workflow must not implement or invoke `mcc build`")

    docs = read("docs/release-process.md")
    for needle in (
        workflow_path,
        package_path,
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "ReleaseSafe",
        "SHA256SUMS",
        "release inventory",
        "CycloneDX SBOM",
        "THIRD-PARTY-LICENSES.md",
        "gh release upload",
        "minisign/cosign",
    ):
        if needle not in docs:
            fail(f"docs/release-process.md does not document release artifact requirement {needle!r}")


def main() -> None:
    require_workflow_actions_pinned()

    zon = read("build.zig.zon")
    version = zon_field(zon, "version")
    if version != EXPECTED_VERSION:
        fail(f"build.zig.zon version is {version!r}, want {EXPECTED_VERSION!r}")

    minimum_zig = zon_field(zon, "minimum_zig_version")
    zigversion = read(".zigversion").strip()
    if minimum_zig != zigversion:
        fail(f"minimum_zig_version {minimum_zig!r} does not match .zigversion {zigversion!r}")

    compiler_build = read("build/compiler.zig")
    require_contains("build/compiler.zig", 'b.option([]const u8, "version"')
    require_contains("build/compiler.zig", f'orelse "{EXPECTED_VERSION}"')
    require_contains("src/main.zig", "@import(\"build_options\")")
    require_contains("src/main.zig", "build_options.version")

    for path in ("SECURITY.md", "STABILITY.md", "CHANGELOG.md", "docs/release-process.md"):
        require_contains(path, EXPECTED_VERSION)
    require_contains("docs/release-process.md", f"LLVM {EXPECTED_LLVM_MAJOR}")
    require_contains("docs/release-process.md", "tools/bench/nightly-baseline.tsv")
    require_contains("docs/release-process.md", "nightly QEMU benchmark workflow")

    if "root_module.addOptions(\"build_options\"" not in compiler_build:
        fail("build/compiler.zig does not expose build_options to src/main.zig")

    ci = read(".github/workflows/ci.yml")
    require_contains(".github/workflows/ci.yml", f"runs-on: {EXPECTED_UBUNTU_RUNNER}")
    require_contains(".github/workflows/ci.yml", f'MC_LLVM_MAJOR: "{EXPECTED_LLVM_MAJOR}"')
    require_contains(".github/workflows/ci.yml", f"clang-{EXPECTED_LLVM_MAJOR} lld-{EXPECTED_LLVM_MAJOR} llvm-{EXPECTED_LLVM_MAJOR}")
    require_contains(".github/workflows/ci.yml", f"/usr/lib/llvm-{EXPECTED_LLVM_MAJOR}/bin")
    if "ubuntu-latest" in ci:
        fail(".github/workflows/ci.yml must not use ubuntu-latest for compiler qualification")
    for needle in (
        "runs-on: macos-15",
        f'MC_LLVM_MAJOR: "{EXPECTED_LLVM_MAJOR}"',
        f"brew --prefix llvm@{EXPECTED_LLVM_MAJOR}",
        f"brew install llvm@{EXPECTED_LLVM_MAJOR}",
        '"$LLVM18_PREFIX/bin/clang" --version',
        '"$LLVM18_PREFIX/bin/llvm-as" --version',
        '"$LLVM18_PREFIX/bin/llc" --version',
        '"$LLVM18_PREFIX/bin/opt" --version',
        'zig build fast -j"$MC_HOST_JOBS"',
    ):
        require_contains(".github/workflows/ci.yml", needle)
    if re.search(r"runs-on:\s*macos-latest\b", ci):
        fail(".github/workflows/ci.yml must not use macos-latest for native macOS qualification")

    nightly_fuzz_path = ".github/workflows/nightly-fuzz.yml"
    nightly_fuzz = read(nightly_fuzz_path)
    for needle in (
        "schedule:",
        "workflow_dispatch:",
        "runs-on: ubuntu-24.04",
        f'MC_LLVM_MAJOR: "{EXPECTED_LLVM_MAJOR}"',
        f"clang-{EXPECTED_LLVM_MAJOR} lld-{EXPECTED_LLVM_MAJOR} llvm-{EXPECTED_LLVM_MAJOR}",
        f"/usr/lib/llvm-{EXPECTED_LLVM_MAJOR}/bin",
        "zig build preflight",
        "zig build install",
        "SEED_START",
        "date -u +%Y%j",
        "python3 tools/fuzz/mcfuzz.py run",
        '--start "$SEED_START"',
        "--trapping",
        "python3 tools/fuzz/mcfuzz.py corpus",
        "tools/fuzz/mcfuzz.py shrink",
        "tools/fuzz/corpus/",
    ):
        require_contains(nightly_fuzz_path, needle)
    for oracle in (
        "differential",
        "robust",
        "failclosed",
        "determinism",
        "pipeline",
        "metamorphic",
        "optlevel",
        "floatbits",
        "reference",
    ):
        if f"oracle: {oracle}" not in nightly_fuzz:
            fail(f"{nightly_fuzz_path} missing mcfuzz oracle {oracle!r}")
    if "ubuntu-latest" in nightly_fuzz:
        fail(f"{nightly_fuzz_path} must not use ubuntu-latest for compiler qualification")

    require_nightly_bench_metadata()
    require_release_artifact_metadata()

    dockerfile = read("Dockerfile")
    require_contains("Dockerfile", f"FROM {EXPECTED_DOCKER_BASE_IMAGE}")
    require_contains("Dockerfile", f"ARG LLVM_MAJOR={EXPECTED_LLVM_MAJOR}")
    require_contains("Dockerfile", "ENV MC_LLVM_MAJOR=${LLVM_MAJOR}")
    require_contains("Dockerfile", "clang-${LLVM_MAJOR} lld-${LLVM_MAJOR} llvm-${LLVM_MAJOR}")
    if not re.search(r"(?m)^FROM\s+ubuntu:24\.04@sha256:[0-9a-f]{64}\s*$", dockerfile):
        fail("Dockerfile base image must be pinned to the Ubuntu 24.04 manifest-list digest")
    if re.search(r"(?m)^FROM\s+ubuntu:24\.04\s*$", dockerfile):
        fail("Dockerfile base image must not float by tag alone")
    for zig_sha256 in EXPECTED_ZIG_LINUX_SHA256:
        require_contains("Dockerfile", zig_sha256)
    for needle in (
        "zig_sha256=",
        "sha256sum -c -",
        "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz",
    ):
        require_contains("Dockerfile", needle)
    if "urllib.request.urlopen" in dockerfile:
        fail("Dockerfile must not trust Zig download integrity from a build-time index fetch")
    if "sort -V | tail -n1" in dockerfile or "llvm-*" in dockerfile:
        fail("Dockerfile must select the pinned LLVM major, not the highest installed one")

    print("PASS: release-metadata-test - version, Docker/Zig/LLVM/action pins, nightly fuzz/bench, release artifacts, and process docs are in sync")


if __name__ == "__main__":
    main()
