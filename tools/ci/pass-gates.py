#!/usr/bin/env python3
"""CI PASS anti-vacuity checks derived from build/tiers.zig."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
TIERS = ROOT / "build" / "tiers.zig"
CI = ROOT / ".github" / "workflows" / "ci.yml"

ARRAYS = {
    "riscv-qemu-validation": "riscv_qemu_validation",
    "ci-m0-pass": "ci_m0_pass_assertions",
}

MIN_GATE_COUNTS = {
    # Match the current assertion-list sizes. Any intentional reduction should
    # update this contract explicitly so CI cannot quietly become less probative.
    "ci-m0-pass": 28,
    "riscv-qemu-validation": 32,
}


def fail(message: str) -> None:
    print(f"FAIL: ci-pass-gates-test - {message}", file=sys.stderr)
    sys.exit(1)


def read(path: pathlib.Path) -> str:
    if not path.is_file():
        fail(f"missing {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def names_in_array(source: str, zig_name: str) -> list[str]:
    match = re.search(
        rf"const\s+{re.escape(zig_name)}\s*=\s*\[_\]\[\]const u8\s*\{{(?P<body>.*?)\n\s*\}};",
        source,
        re.DOTALL,
    )
    if not match:
        fail(f"build/tiers.zig missing array {zig_name}")
    return re.findall(r'"([^"]+)"', match.group("body"))


def block_after(source: str, marker: str, end_marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        fail(f"build/tiers.zig missing {marker!r}")
    end = source.find(end_marker, start)
    if end < 0:
        fail(f"build/tiers.zig missing {end_marker!r} after {marker!r}")
    return source[start:end]


def m0_dependencies(source: str) -> set[str]:
    block = block_after(source, 'const m0_step = b.step("m0"', 'const fast_step = b.step("fast"')
    return set(re.findall(r'm0_step\.dependOn\(ctx\.cmd\("([^"]+)"\)\);', block))


def require_unique(label: str, names: list[str]) -> None:
    seen: set[str] = set()
    dupes: list[str] = []
    for name in names:
        if name in seen:
            dupes.append(name)
        seen.add(name)
    if dupes:
        fail(f"{label} has duplicate gate(s): {', '.join(sorted(set(dupes)))}")


def require_count_floor(tier: str, zig_name: str, names: list[str]) -> None:
    minimum = MIN_GATE_COUNTS.get(tier)
    if minimum is None:
        return
    if len(names) < minimum:
        fail(f"{zig_name} has {len(names)} gate(s), below required floor {minimum}")


def tier_names(tier: str) -> list[str]:
    zig_name = ARRAYS.get(tier)
    if zig_name is None:
        fail(f"unknown tier {tier!r}; expected one of {', '.join(sorted(ARRAYS))}")
    return names_in_array(read(TIERS), zig_name)


def check_static() -> None:
    source = read(TIERS)
    deps = m0_dependencies(source)

    for tier, zig_name in ARRAYS.items():
        names = names_in_array(source, zig_name)
        if not names:
            fail(f"{zig_name} is empty")
        require_unique(zig_name, names)
        require_count_floor(tier, zig_name, names)
        if tier == "ci-m0-pass":
            missing = [name for name in names if name not in deps]
            if missing:
                fail(f"{zig_name} contains non-m0 dependency gate(s): {', '.join(missing)}")

    ci = read(CI)
    required_snippets = (
        "python3 tools/ci/pass-gates.py assert --tier ci-m0-pass --log m0.log",
        "python3 tools/ci/pass-gates.py assert --tier riscv-qemu-validation --log riscv-qemu-validation.log",
        "python3 tools/ci/pass-gates.py names --tier ci-m0-pass",
    )
    for snippet in required_snippets:
        if snippet not in ci:
            fail(f".github/workflows/ci.yml missing {snippet!r}")

    stale_fragments = (
        "for g in async-test async-irq-test",
        "smode-timer-test llvm-smode-timer-test",
    )
    for fragment in stale_fragments:
        if fragment in ci:
            fail(f".github/workflows/ci.yml still has hard-coded PASS gate fragment {fragment!r}")

    print("PASS: ci-pass-gates-test - CI PASS assertions are derived from build/tiers.zig")


def assert_log(tier: str, log_path: pathlib.Path) -> None:
    names = tier_names(tier)
    require_unique(tier, names)
    if not log_path.is_file():
        fail(f"missing log {log_path}")
    log = log_path.read_text(encoding="utf-8", errors="replace")
    missing = [name for name in names if re.search(rf"^PASS: {re.escape(name)}(?:\s|$)", log, re.MULTILINE) is None]
    if missing:
        fail(f"{log_path} missing PASS line(s) for {tier}: {', '.join(missing)}")
    print(f"PASS: ci-pass-gates-test - {log_path} contains {len(names)} required {tier} PASS line(s)")


def print_names(tier: str) -> None:
    for name in tier_names(tier):
        print(name)


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    check = sub.add_parser("check", help="validate tiers.zig and CI wiring")
    check.set_defaults(fn=lambda args: check_static())

    names = sub.add_parser("names", help="print gate names for a tier")
    names.add_argument("--tier", required=True)
    names.set_defaults(fn=lambda args: print_names(args.tier))

    assert_parser = sub.add_parser("assert", help="assert a log contains every PASS line for a tier")
    assert_parser.add_argument("--tier", required=True)
    assert_parser.add_argument("--log", required=True, type=pathlib.Path)
    assert_parser.set_defaults(fn=lambda args: assert_log(args.tier, args.log))

    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
