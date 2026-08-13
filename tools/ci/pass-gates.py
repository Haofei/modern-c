#!/usr/bin/env python3
"""CI PASS anti-vacuity checks derived from manifests and build tiers."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
TIERS = ROOT / "build" / "tiers.zig"
CI = ROOT / ".github" / "workflows" / "ci.yml"
GATE_MANIFEST = ROOT / "docs" / "gate-manifest.json"

ARRAYS = {
    "riscv-qemu-validation": "riscv_qemu_validation",
}

MIN_GATE_COUNTS = {
    # Match the current assertion-list sizes. Any intentional reduction should
    # update this contract explicitly so CI cannot quietly become less probative.
    "riscv-qemu-validation": 6,
}
MIN_M0_DEPENDENCIES = 20


def fail(message: str) -> None:
    print(f"FAIL: ci-pass-gates-test - {message}", file=sys.stderr)
    sys.exit(1)


def read(path: pathlib.Path) -> str:
    if not path.is_file():
        fail(f"missing {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def read_json(path: pathlib.Path) -> object:
    if not path.is_file():
        fail(f"missing {path.relative_to(ROOT)}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)} is not valid JSON: {exc}")


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
    if tier == "ci-m0-pass":
        return ci_pass_assertion_names(tier)
    zig_name = ARRAYS.get(tier)
    if zig_name is None:
        expected = sorted(set(ARRAYS) | {"ci-m0-pass"})
        fail(f"unknown tier {tier!r}; expected one of {', '.join(expected)}")
    return names_in_array(read(TIERS), zig_name)


def ci_pass_assertions() -> dict[str, object]:
    manifest = read_json(GATE_MANIFEST)
    if not isinstance(manifest, dict):
        fail("docs/gate-manifest.json must be a JSON object")
    assertions = manifest.get("ci_pass_assertions")
    if not isinstance(assertions, dict):
        fail("docs/gate-manifest.json missing ci_pass_assertions object")
    return assertions


def ci_pass_assertion_spec(tier: str) -> dict[str, object]:
    assertions = ci_pass_assertions()
    spec = assertions.get(tier)
    if not isinstance(spec, dict):
        fail(f"docs/gate-manifest.json missing ci_pass_assertions.{tier}")
    return spec


def ci_pass_assertion_names(tier: str) -> list[str]:
    spec = ci_pass_assertion_spec(tier)
    gates = spec.get("gates")
    if not isinstance(gates, list) or not gates:
        fail(f"ci_pass_assertions.{tier}.gates must be a non-empty list")
    names: list[str] = []
    for gate in gates:
        if not isinstance(gate, str) or not gate:
            fail(f"ci_pass_assertions.{tier}.gates contains a non-string gate")
        names.append(gate)
    return names


def ci_pass_assertion_build_tier(tier: str) -> str:
    spec = ci_pass_assertion_spec(tier)
    build_tier = spec.get("build_tier")
    if not isinstance(build_tier, str) or not build_tier:
        fail(f"ci_pass_assertions.{tier}.build_tier must be a non-empty string")
    return build_tier


def ci_pass_assertion_min_count(tier: str) -> int:
    spec = ci_pass_assertion_spec(tier)
    minimum = spec.get("min_count")
    if not isinstance(minimum, int) or minimum < 1:
        fail(f"ci_pass_assertions.{tier}.min_count must be a positive integer")
    return minimum


def require_manifest_count_floor(tier: str, names: list[str]) -> None:
    minimum = ci_pass_assertion_min_count(tier)
    if len(names) < minimum:
        fail(f"ci_pass_assertions.{tier} has {len(names)} gate(s), below required floor {minimum}")


def check_static() -> None:
    source = read(TIERS)
    deps = m0_dependencies(source)
    if len(deps) < MIN_M0_DEPENDENCIES:
        fail(f"m0 has {len(deps)} unique ctx.cmd dependency gate(s), below required floor {MIN_M0_DEPENDENCIES}")

    names = ci_pass_assertion_names("ci-m0-pass")
    require_unique("ci_pass_assertions.ci-m0-pass", names)
    require_manifest_count_floor("ci-m0-pass", names)
    build_tier = ci_pass_assertion_build_tier("ci-m0-pass")
    if build_tier != "m0":
        fail(f"ci_pass_assertions.ci-m0-pass targets unsupported build tier {build_tier!r}")
    missing = [name for name in names if name not in deps]
    if missing:
        fail(f"ci_pass_assertions.ci-m0-pass contains non-m0 dependency gate(s): {', '.join(missing)}")

    for tier, zig_name in ARRAYS.items():
        names = names_in_array(source, zig_name)
        if not names:
            fail(f"{zig_name} is empty")
        require_unique(zig_name, names)
        require_count_floor(tier, zig_name, names)

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

    print("PASS: ci-pass-gates-test - CI PASS assertions are derived from docs/gate-manifest.json and tier definitions")


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
