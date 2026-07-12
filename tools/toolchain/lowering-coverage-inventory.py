#!/usr/bin/env python3
"""Static inventory for the lowering-coverage ratchet surface."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MIN_LOWER_C_FILES = 40
MIN_LOWER_LLVM_FILES = 12
MIN_LOWER_C_UNIVERSE = 1305
MIN_LOWER_LLVM_UNIVERSE = 409


def fail(message: str) -> None:
    print(f"FAIL: lowering-coverage-inventory - {message}", file=sys.stderr)
    sys.exit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    return full.read_text(encoding="utf-8")


def backend_files(prefix: str) -> list[Path]:
    return sorted(
        path
        for path in (ROOT / "src").glob(f"{prefix}*.zig")
        if path.name != f"{prefix}_tests.zig" and path.name != "lower_cov.zig"
    )


def baseline_row(text: str, name: str) -> tuple[int, int, int]:
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) == 4 and parts[0] == name:
            try:
                return int(parts[1]), int(parts[2]), int(parts[3])
            except ValueError:
                fail(f"non-integer baseline row for {name}: {line!r}")
    fail(f"missing baseline row for {name}")


def require_contains(path: str, needle: str) -> None:
    if needle not in read(path):
        fail(f"{path} missing {needle!r}")


def main() -> int:
    lower_c_files = backend_files("lower_c")
    lower_llvm_files = backend_files("lower_llvm")
    if len(lower_c_files) < MIN_LOWER_C_FILES:
        fail(f"only {len(lower_c_files)} lower_c*.zig files found, expected at least {MIN_LOWER_C_FILES}")
    if len(lower_llvm_files) < MIN_LOWER_LLVM_FILES:
        fail(
            f"only {len(lower_llvm_files)} lower_llvm*.zig files found, expected at least {MIN_LOWER_LLVM_FILES}"
        )

    script = read("tools/toolchain/lowering-coverage.sh")
    for needle in (
        'collect_backend_files()',
        'find src -maxdepth 1 -type f -name "${prefix}*.zig"',
        '! -name "${prefix}_tests.zig"',
        '! -name "lower_cov.zig"',
        'collect_backend_files "lower_c"',
        'collect_backend_files "lower_llvm"',
        'lowering-coverage-baseline.tsv',
        'FAIL: lowering-coverage source set shrank',
        'FAIL: lowering-coverage universe shrank',
        'FAIL: lowering coverage regressed',
    ):
        if needle not in script:
            fail(f"tools/toolchain/lowering-coverage.sh missing {needle!r}")
    if re.search(r"src/lower_c\.zig\s+src/lower_llvm\.zig", script):
        fail("tools/toolchain/lowering-coverage.sh must not hard-code only facade backend files")

    baseline = read("tools/toolchain/lowering-coverage-baseline.tsv")
    c_files, c_universe, _ = baseline_row(baseline, "lower_c")
    llvm_files, llvm_universe, _ = baseline_row(baseline, "lower_llvm")
    if c_files < MIN_LOWER_C_FILES or c_universe < MIN_LOWER_C_UNIVERSE:
        fail("lower_c baseline is below the split-backend source/universe floor")
    if llvm_files < MIN_LOWER_LLVM_FILES or llvm_universe < MIN_LOWER_LLVM_UNIVERSE:
        fail("lower_llvm baseline is below the split-backend source/universe floor")

    docs = read("docs/lowering-coverage.md")
    for needle in (
        "src/lower_c*.zig",
        "src/lower_llvm*.zig",
        "currently 40 C backend files and",
        "12 LLVM backend files",
        "tools/toolchain/lowering-coverage-baseline.tsv",
        "or a growing uncovered count fails `zig build lowering-coverage`",
    ):
        if needle not in docs:
            fail(f"docs/lowering-coverage.md missing {needle!r}")

    for path, needle in (
        ("build/hardening.zig", "lowering-coverage"),
        ("build/tiers.zig", 'm0_step.dependOn(ctx.cmd("lowering-coverage"))'),
        ("tools/dev-gates.py", "lowering-coverage-inventory-test"),
    ):
        require_contains(path, needle)

    print(
        "PASS: lowering-coverage-inventory - "
        f"{len(lower_c_files)} C backend files, {len(lower_llvm_files)} LLVM backend files, "
        f"baseline universes {c_universe}/{llvm_universe}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
