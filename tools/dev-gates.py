#!/usr/bin/env python3
"""Recommend focused development gates from the files changed in git.

This is an inner-loop helper, not a release qualification oracle. It chooses a
conservative small set of `zig build` steps for the current edit shape, then
prints the broader confidence/truth gates that still matter before a large merge
or release.
"""

from __future__ import annotations

import argparse
import fnmatch
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Rule:
    patterns: tuple[str, ...]
    gates: tuple[str, ...]
    reason: str
    checks: tuple[str, ...] = ()
    excludes: tuple[str, ...] = ()


RULES: tuple[Rule, ...] = (
    Rule(
        ("src/parser.zig", "src/lexer.zig", "src/loader.zig", "src/diagnostics.zig", "src/main.zig"),
        ("test", "diagnostics-test", "bad-diagnostics-test", "diagnostics-reference-test", "diagnostic-code-inventory-test"),
        "front-end and diagnostics changes need unit/spec coverage, transcript locks, generated diagnostic reference, and code ownership",
    ),
    Rule(
        ("src/sema*.zig", "src/generic_precheck.zig", "src/monomorphize.zig", "src/sema_*.zig"),
        ("test", "bad-diagnostics-test", "c-test", "diff-backend"),
        "semantic changes need spec diagnostics, C emission sweep, and backend parity",
        excludes=("src/*_tests.zig",),
    ),
    Rule(
        ("src/mir*.zig", "src/ir.zig", "src/hir.zig", "src/eval.zig", "src/numeric.zig"),
        ("test", "c-test", "llvm-test", "diff-backend", "fuzz-reference"),
        "middle-end and evaluator changes can affect both backends and the reference oracle",
        excludes=("src/*_tests.zig",),
    ),
    Rule(
        ("src/lower_c*.zig",),
        ("test", "c-test", "diff-backend", "lowering-coverage"),
        "C backend changes need C sweep, parity, and lowering coverage ratchet",
        excludes=("src/*_tests.zig",),
    ),
    Rule(
        ("src/lower_llvm*.zig",),
        ("test", "llvm-test", "llvm-obj-test", "diff-backend", "lowering-coverage"),
        "LLVM backend changes need textual/object LLVM gates, parity, and lowering coverage ratchet",
        excludes=("src/*_tests.zig",),
    ),
    Rule(
        ("src/async_lower.zig",),
        ("test", "c-test", "llvm-test", "diff-backend", "fuzz-corpus"),
        "async lowering rewrites source before sema and must stay cross-backend equivalent",
    ),
    Rule(
        ("src/*_tests.zig",),
        ("test",),
        "unit test source changes are covered by the compiler unit/spec test step",
    ),
    Rule(
        ("build.zig", "build/*.zig", "tools/ci/pass-gates.py", "tools/m0-parallel.sh"),
        ("test", "ci-pass-gates-test", "fast"),
        "build graph changes need tier anti-drift checks; fast is the broad host-only confidence gate",
    ),
    Rule(
        (".github/workflows/ci.yml", "Dockerfile", "docker-compose.yml", "tools/preflight.sh"),
        ("preflight", "release-metadata-test", "ci-pass-gates-test"),
        "toolchain and CI changes need pinned-toolchain metadata plus preflight",
    ),
    Rule(
        (
            ".github/workflows/release.yml",
            "tools/ci/package-release.py",
            "tools/toolchain/package-release-test.py",
            "tools/toolchain/release-metadata-test.py",
            "docs/release-process.md",
            "SECURITY.md",
            "STABILITY.md",
            "CHANGELOG.md",
            "build.zig.zon",
            ".zigversion",
        ),
        ("release-metadata-test", "package-release-test", "editor-client-test"),
        "release/distribution changes need artifact metadata, packager, and VSIX release hooks",
    ),
    Rule(
        ("tools/toolchain/diagnostics-reference.py", "tools/toolchain/diagnostic-code-inventory.py", "docs/diagnostics.md", "docs/diagnostic-code-inventory.md"),
        ("diagnostics-reference-test", "diagnostic-code-inventory-test", "bad-diagnostics-test"),
        "diagnostic inventory changes need generated reference and ownership checks",
    ),
    Rule(
        ("tools/toolchain/spec-*-sweep.py", "tools/toolchain/llvm-opt-sweep.py"),
        ("test-lint",),
        "spec sweep allowlist changes need fixture-contract lint so codegen fixtures cannot be hidden",
    ),
    Rule(
        ("tools/toolchain/spec-emit-sweep.py",),
        ("sweep",),
        "spec C-emission sweep script changes need the spec C emit sweep",
    ),
    Rule(
        ("tools/toolchain/spec-llvm-sweep.py",),
        ("llvm-sweep",),
        "spec LLVM IR sweep script changes need the spec LLVM sweep",
    ),
    Rule(
        ("tools/toolchain/spec-llvm-obj-sweep.py",),
        ("llvm-spec-obj-sweep",),
        "spec LLVM object sweep script changes need the spec LLVM object sweep",
    ),
    Rule(
        ("tools/toolchain/llvm-opt-sweep.py",),
        ("llvm-opt-sweep",),
        "LLVM optimizer sweep script changes need the optimizer/verifier sweep",
    ),
    Rule(
        ("tools/toolchain/spec_sweep_lib.py",),
        ("sweep", "llvm-sweep", "llvm-spec-obj-sweep", "llvm-opt-sweep"),
        "shared spec sweep parsing changes need every spec-backed emit/object/optimizer sweep",
    ),
    Rule(
        ("docs/**/*.md", "docs/*.md", "*.md"),
        (),
        "generic documentation changes need whitespace/patch sanity, not compiler execution",
        ("git diff --check",),
    ),
    Rule(
        ("tests/spec/*.mc",),
        (),
        "spec fixtures are routed from their SPEC phase metadata",
    ),
    Rule(
        ("tests/c_emit/bad/*.mc",),
        ("bad-diagnostics-test", "c-test"),
        "bad C-emission fixtures need golden diagnostics and reject-sweep coverage",
    ),
    Rule(
        ("tests/c_emit/*.mc", "tools/lib/host-tests.tsv", "tools/lib/host-harness.sh"),
        ("c-test", "diff-backend", "llvm-c-sweep"),
        "host C fixtures are cross-backend parity surface",
    ),
    Rule(
        ("tests/llvm/*.mc", "tools/toolchain/llvm-*.sh", "tools/toolchain/llvm-c-*.py"),
        ("llvm-test", "llvm-obj-test", "llvm-sweep", "llvm-c-obj-sweep"),
        "LLVM fixtures and scripts need textual, object, and sweep coverage",
    ),
    Rule(
        ("tools/fuzz/*", "tools/fuzz/corpus/*"),
        ("diff-fuzz", "fuzz-robust", "fuzz-reference", "fuzz-corpus"),
        "fuzzer changes need deterministic oracle families and persisted corpus replay",
    ),
    Rule(
        ("tools/lsp/*", "editors/vscode/*", "editors/vscode/**/*"),
        ("lsp-test", "editor-client-test"),
        "editor/LSP changes need protocol and extension packaging checks",
    ),
    Rule(
        ("kernel/**/*", "std/**/*", "tests/qemu/**/*", "tools/arch/*", "tools/proc/*", "tools/mem/*", "tools/net/*", "tools/fs/*"),
        ("fast", "riscv-qemu-validation"),
        "kernel/std/QEMU changes need host confidence plus the focused RISC-V board surrogate",
    ),
)


def run_git(args: list[str]) -> list[str]:
    try:
        output = subprocess.check_output(["git", *args], cwd=ROOT, text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"git {' '.join(args)} failed with exit {exc.returncode}") from exc
    return [line.strip() for line in output.splitlines() if line.strip()]


def changed_files(base: str | None, staged: bool, unstaged: bool, all_changes: bool) -> list[str]:
    files: set[str] = set()
    if base:
        files.update(run_git(["diff", "--name-only", f"{base}...HEAD"]))
    if staged or all_changes:
        files.update(run_git(["diff", "--cached", "--name-only"]))
    if unstaged or all_changes:
        files.update(run_git(["diff", "--name-only"]))
        files.update(run_git(["ls-files", "--others", "--exclude-standard"]))
    return sorted(files)


def matches(path: str, pattern: str) -> bool:
    if "/" in pattern:
        return PurePosixPath(path).match(pattern)
    return fnmatch.fnmatch(path, pattern)


def spec_fixture_gates(path: str) -> tuple[list[str], list[str]]:
    gates = ["test"]
    reasons = ["spec fixture metadata and inline EXPECT contracts are checked by compiler unit/spec tests"]
    try:
        with (ROOT / path).open("r", encoding="utf-8") as source:
            for _, line in zip(range(20), source):
                prefix = "// SPEC: phase="
                stripped = line.strip()
                if not stripped.startswith(prefix):
                    continue
                phases = {part.strip() for part in stripped[len(prefix) :].split(",")}
                if "lower-c" in phases:
                    gates.append("sweep")
                    reasons.append("lower-c spec fixtures need the spec emit-C sweep, not the tests/c_emit c-test corpus")
                if "lower-ir" in phases or "llvm" in phases:
                    gates.append("llvm-sweep")
                    reasons.append("lower-ir/LLVM spec fixtures need the spec LLVM IR sweep")
                return gates, reasons
    except OSError:
        pass
    reasons.append("missing or unreadable SPEC phase metadata defaults to the conservative unit/spec gate")
    return gates, reasons


def select_gates(paths: list[str]) -> tuple[list[str], list[str], list[str]]:
    gates: list[str] = []
    checks: list[str] = []
    reasons: list[str] = []
    seen_gates: set[str] = set()
    seen_checks: set[str] = set()
    seen_reasons: set[str] = set()
    for path in paths:
        if PurePosixPath(path).match("tests/spec/*.mc"):
            spec_gates, spec_reasons = spec_fixture_gates(path)
            for gate in spec_gates:
                if gate not in seen_gates:
                    seen_gates.add(gate)
                    gates.append(gate)
            for reason in spec_reasons:
                if reason not in seen_reasons:
                    seen_reasons.add(reason)
                    reasons.append(reason)
            continue
        for rule in RULES:
            if any(matches(path, pattern) for pattern in rule.patterns) and not any(matches(path, pattern) for pattern in rule.excludes):
                for gate in rule.gates:
                    if gate not in seen_gates:
                        seen_gates.add(gate)
                        gates.append(gate)
                for check in rule.checks:
                    if check not in seen_checks:
                        seen_checks.add(check)
                        checks.append(check)
                if rule.reason not in seen_reasons:
                    seen_reasons.add(rule.reason)
                    reasons.append(rule.reason)
    if paths and not gates and not checks:
        gates = ["test"]
        reasons = ["unmapped changes default to compiler unit/spec tests"]
    return gates, checks, reasons


def main() -> int:
    parser = argparse.ArgumentParser(description="Recommend focused gates for changed files")
    parser.add_argument("--base", help="compare base...HEAD, for example origin/master")
    parser.add_argument("--staged", action="store_true", help="include staged changes")
    parser.add_argument("--unstaged", action="store_true", help="include unstaged and untracked changes")
    parser.add_argument("--all", action="store_true", help="include staged, unstaged, and untracked changes")
    parser.add_argument("paths", nargs="*", help="explicit paths to classify instead of reading git")
    args = parser.parse_args()

    paths = sorted(set(args.paths)) if args.paths else changed_files(args.base, args.staged, args.unstaged, args.all or not (args.base or args.staged or args.unstaged))
    gates, checks, reasons = select_gates(paths)

    if not paths:
        print("No changed files found.")
        return 0

    print("Changed files:")
    for path in paths:
        print(f"  {path}")

    print("\nFocused checks:")
    for check in checks:
        print(f"  {check}")
    if gates:
        print("  zig build " + " ".join(gates))

    if reasons:
        print("\nWhy:")
        for reason in reasons:
            print(f"  - {reason}")

    print("\nConfidence gates:")
    print("  zig build fast")
    print("  tools/m0-parallel.sh <jobs>    # broad local milestone check when the slice is large")

    print("\nTruth gate:")
    print("  zig build m0                   # required before release/production claims")
    return 0


if __name__ == "__main__":
    sys.exit(main())
