#!/usr/bin/env python3

import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: parallel-runner-test - {message}")


def read(path: str) -> str:
    return (ROOT / path).read_text()


def tier_gates(source: str, start: str, end: str) -> set[str]:
    section = source.split(start, 1)[1].split(end, 1)[0]
    return set(re.findall(r'ctx\.cmd\("([^"]+)"\)', section))


def main() -> None:
    scripts = [
        "tools/lib/test-env.sh",
        "tools/fast-parallel.sh",
        "tools/m0-parallel.sh",
    ]
    syntax = subprocess.run(
        ["bash", "-n", *scripts],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if syntax.returncode != 0:
        fail(syntax.stderr.strip())

    allocation = subprocess.run(
        [
            "bash",
            "-c",
            ". tools/lib/test-env.sh; "
            'printf "%s %s %s" '
            '"$(mc_inner_jobs 14 14)" '
            '"$(mc_inner_jobs 4 14)" '
            '"$(mc_inner_jobs 1 14)"',
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if allocation.returncode != 0 or allocation.stdout != "1 3 14":
        fail(f"nested-worker allocation is not bounded: {allocation.stdout!r}")

    fast = read("tools/fast-parallel.sh")
    m0 = read("tools/m0-parallel.sh")
    for name, source in (("fast", fast), ("m0", m0)):
        if 'mc_inner_jobs "$' not in source or 'export JOBS=' not in source:
            fail(f"{name} runner does not cap nested worker pools")
        if "${ms:-0}" not in source:
            fail(f"{name} runner no longer starts known longest gates first")
    if '--full' not in fast or "MC_FAST_FULL_FUZZ_COUNT:-300" not in fast:
        fail("fast runner lacks complete 300-seed mode")
    if "MC_REQUIRE_TOOLS" not in m0 or 'grep -q "^SKIP:"' not in m0:
        fail("m0 runner does not fail strict qualification skips")

    tiers = read("build/tiers.zig")
    fast_gates = tier_gates(
        tiers,
        'const fast_step = b.step("fast"',
        'const c0_step = b.step("c0"',
    )
    m0_gates = tier_gates(
        tiers,
        'const m0_step = b.step("m0"',
        'const fast_step = b.step("fast"',
    )
    if len(fast_gates) < 30 or len(m0_gates) <= len(fast_gates):
        fail("tier extraction boundaries no longer describe full gate inventories")

    print(
        "PASS: parallel-runner-test - full gate inventories use bounded nested "
        "workers, strict skip handling, and longest-first scheduling"
    )


if __name__ == "__main__":
    main()
