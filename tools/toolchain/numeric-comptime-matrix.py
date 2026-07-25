#!/usr/bin/env python3

import subprocess
import sys


WIDTHS = (8, 16, 32, 64, 128)


def unsigned_max(bits: int) -> int:
    return (1 << bits) - 1


def signed_min(bits: int) -> int:
    return -(1 << (bits - 1))


def accepted_source() -> str:
    lines = ["fn accepted_numeric_matrix() -> void {", "    comptime {"]
    for bits in WIDTHS:
        maximum = unsigned_max(bits)
        lines.extend(
            [
                f"        let w{bits}: wrap<u{bits}> = {maximum};",
                f"        let s{bits}: sat<u{bits}> = {maximum};",
                f"        assert(((w{bits} + (1 as wrap<u{bits}>)) as u{bits}) == 0);",
                f"        assert(((s{bits} + (1 as sat<u{bits}>)) as u{bits}) == {maximum});",
                f"        assert(((w{bits} - (1 as wrap<u{bits}>)) as u{bits}) == {maximum - 1});",
                f"        assert((((0 as sat<u{bits}>) - (1 as sat<u{bits}>)) as u{bits}) == 0);",
                f"        assert(((w{bits} * (2 as wrap<u{bits}>)) as u{bits}) == {maximum - 1});",
                f"        assert(((s{bits} * (2 as sat<u{bits}>)) as u{bits}) == {maximum});",
                f"        assert(((w{bits} << (1 as wrap<u{bits}>)) as u{bits}) == {maximum - 1});",
                f"        assert(((w{bits} >> (1 as wrap<u{bits}>)) as u{bits}) == {maximum >> 1});",
            ]
        )
    lines.extend(["    }", "}", ""])
    return "\n".join(lines)


def rejected_source() -> str:
    lines: list[str] = []
    for bits in WIDTHS:
        maximum = unsigned_max(bits)
        minimum = signed_min(bits)
        lines.extend(
            [
                f"fn reject_overflow_u{bits}() -> void {{ comptime {{",
                f"    let maximum: u{bits} = {maximum};",
                f"    let invalid: u{bits} = maximum + 1;",
                "} }",
                f"fn reject_shift_u{bits}() -> void {{ comptime {{",
                f"    let one: u{bits} = 1;",
                f"    let invalid: u{bits} = one << {bits};",
                "} }",
                f"fn reject_neg_i{bits}() -> void {{ comptime {{",
                f"    let minimum: i{bits} = {minimum};",
                f"    let invalid: i{bits} = -minimum;",
                "} }",
            ]
        )
    return "\n".join(lines) + "\n"


def run(mcc: str, source: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [mcc, "check", "-"],
        input=source,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def main() -> int:
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    accepted = run(mcc, accepted_source())
    if accepted.returncode != 0:
        print("FAIL: numeric-comptime-matrix accepted cases failed", file=sys.stderr)
        print(accepted.stderr, file=sys.stderr)
        return 1

    rejected = run(mcc, rejected_source())
    expected = len(WIDTHS) * 3
    actual = rejected.stderr.count("E_COMPTIME_TRAP")
    if rejected.returncode == 0 or actual != expected:
        print(
            f"FAIL: numeric-comptime-matrix expected {expected} checked traps, got {actual}",
            file=sys.stderr,
        )
        print(rejected.stderr, file=sys.stderr)
        return 1

    print(
        "PASS: numeric-comptime-matrix — checked/wrap/sat and shift/negation "
        "boundaries hold for 8/16/32/64/128-bit scalars"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
