#!/usr/bin/env python3

import subprocess
import sys


WIDTHS = (8, 16, 32, 64, 128)
COMMAND_TIMEOUT_SECONDS = 20


def unsigned_max(bits: int) -> int:
    return (1 << bits) - 1


def signed_min(bits: int) -> int:
    return -(1 << (bits - 1))


def accepted_source() -> str:
    lines = [
        "type WrapByte = wrap<u8>;",
        "struct DomainPair { a: wrap<u8>, b: wrap<u8> }",
        "const fn generic_add(comptime T: type, a: T, b: T) -> T { return a + b; }",
        "const fn f32_edge() -> f32 { return 16777216.0; }",
        "const fn f32_one() -> f32 { return 1.0; }",
        "const fn validate_arrays(comptime a: [2]u8, comptime b: [2]u8) -> u8 {",
        "    comptime { assert(a[0] == 1); assert(b[0] == 3); }",
        "    return 0;",
        "}",
        "fn accepted_numeric_matrix() -> void {",
        "    comptime {",
    ]
    for bits in WIDTHS:
        maximum = unsigned_max(bits)
        lines.extend(
            [
                f"        let w{bits}: wrap<u{bits}> = {maximum};",
                f"        let s{bits}: sat<u{bits}> = {maximum};",
                # Observe the domain result before any representation-erasing cast.
                f"        assert(w{bits} + (1 as wrap<u{bits}>) == (0 as wrap<u{bits}>));",
                f"        assert((w{bits} + (1 as wrap<u{bits}>)) + (1 as wrap<u{bits}>) == (1 as wrap<u{bits}>));",
                f"        assert(s{bits} + (1 as sat<u{bits}>) == ({maximum} as sat<u{bits}>));",
                f"        assert(w{bits} - (1 as wrap<u{bits}>) == ({maximum - 1} as wrap<u{bits}>));",
                f"        assert((0 as sat<u{bits}>) - (1 as sat<u{bits}>) == (0 as sat<u{bits}>));",
                f"        assert(w{bits} * (2 as wrap<u{bits}>) == ({maximum - 1} as wrap<u{bits}>));",
                f"        assert(s{bits} * (2 as sat<u{bits}>) == ({maximum} as sat<u{bits}>));",
                f"        assert(w{bits} << (1 as wrap<u{bits}>) == ({maximum - 1} as wrap<u{bits}>));",
                f"        assert(w{bits} >> (1 as wrap<u{bits}>) == ({maximum >> 1} as wrap<u{bits}>));",
            ]
        )
    lines.extend(
        [
            "        let inferred = 255 as wrap<u8>;",
            "        assert(inferred + inferred == (254 as wrap<u8>));",
            "        let projected: [2]wrap<u8> = .{ 255, 1 };",
            "        assert(projected[0] + projected[1] == (0 as wrap<u8>));",
            "        let pair: DomainPair = .{ .a = 255, .b = 1 };",
            "        assert(pair.a + pair.b == (0 as wrap<u8>));",
            "        assert((generic_add(WrapByte, 255, 1) as u8) == 0);",
            "        let edge: f32 = 16777216.0;",
            "        let one: f32 = 1.0;",
            "        assert((edge + one) - edge == 0.0);",
            "        assert((f32_edge() + f32_one()) - f32_edge() == 0.0);",
            "        let upper: u128 = 170141183460469231731687303715884105728.0 as u128;",
            "        assert(upper == (1 as u128) << 127);",
            "        assert(validate_arrays(.{ 1, 2 }, .{ 3, 4 }) == 0);",
            "    }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def rejected_cases() -> list[tuple[str, str]]:
    cases: list[tuple[str, str]] = []
    for bits in WIDTHS:
        maximum = unsigned_max(bits)
        minimum = signed_min(bits)
        cases.extend(
            [
                (
                    f"invalid_overflow_u{bits}",
                    "\n".join(
                        [
                            f"fn reject_overflow_u{bits}() -> void {{ comptime {{",
                            f"    let maximum: u{bits} = {maximum};",
                            f"    let invalid_overflow_u{bits}: u{bits} = maximum + 1;",
                            "} }",
                            "",
                        ]
                    ),
                ),
                (
                    f"invalid_shift_u{bits}",
                    "\n".join(
                        [
                            f"fn reject_shift_u{bits}() -> void {{ comptime {{",
                            f"    let one: u{bits} = 1;",
                            f"    let invalid_shift_u{bits}: u{bits} = one << {bits};",
                            "} }",
                            "",
                        ]
                    ),
                ),
                (
                    f"invalid_negation_i{bits}",
                    "\n".join(
                        [
                            f"fn reject_neg_i{bits}() -> void {{ comptime {{",
                            f"    let minimum: i{bits} = {minimum};",
                            f"    let invalid_negation_i{bits}: i{bits} = -minimum;",
                            "} }",
                            "",
                        ]
                    ),
                ),
                (
                    f"invalid_context_u{bits}",
                    f"const invalid_context_u{bits}: u{bits} = {maximum} + 1;\n",
                ),
            ]
        )
    cases.extend(
        [
            (
                "invalid_inferred_wrap",
                "fn reject() -> void { comptime { "
                "let invalid_inferred_wrap = 255 as wrap<u8>; "
                "assert(invalid_inferred_wrap + invalid_inferred_wrap == (0 as wrap<u8>)); } }\n",
            ),
            (
                "invalid_projected_wrap",
                "fn reject() -> void { comptime { "
                "let xs: [2]wrap<u8> = .{ 255, 1 }; "
                "let invalid_projected_wrap = xs[0] + xs[1]; "
                "assert(invalid_projected_wrap == (1 as wrap<u8>)); } }\n",
            ),
            (
                "invalid_struct_wrap",
                "struct Pair { a: wrap<u8>, b: wrap<u8> }\n"
                "fn reject() -> void { comptime { "
                "let p: Pair = .{ .a = 255, .b = 1 }; "
                "let invalid_struct_wrap = p.a + p.b; "
                "assert(invalid_struct_wrap == (1 as wrap<u8>)); } }\n",
            ),
            (
                "invalid_generic_wrap",
                "type W = wrap<u8>;\n"
                "const fn add(comptime T: type, a: T, b: T) -> T { return a + b; }\n"
                "fn reject() -> void { comptime { "
                "let invalid_generic_wrap: u8 = add(W, 255, 1) as u8; "
                "assert(invalid_generic_wrap == 1); } }\n",
            ),
            (
                "invalid_f32_local",
                "fn reject() -> void { comptime { "
                "let edge: f32 = 16777216.0; let one: f32 = 1.0; "
                "let invalid_f32_local: f32 = (edge + one) - edge; "
                "assert(invalid_f32_local == 1.0); } }\n",
            ),
            (
                "invalid_f32_return",
                "const fn edge() -> f32 { return 16777216.0; }\n"
                "const fn one() -> f32 { return 1.0; }\n"
                "fn reject() -> void { comptime { "
                "let invalid_f32_return: f32 = (edge() + one()) - edge(); "
                "assert(invalid_f32_return == 1.0); } }\n",
            ),
            (
                "invalid_upper_u128",
                "fn reject() -> void { comptime { "
                "let invalid_upper_u128: u128 = "
                "170141183460469231731687303715884105728.0 as u128; "
                "assert(invalid_upper_u128 == 0); } }\n",
            ),
            (
                "invalid_aggregate_params",
                "const fn invalid_aggregate_params(comptime a: [2]u8, comptime b: [2]u8) -> u8 { "
                "comptime { assert(a[0] == b[0]); } return 0; }\n"
                "fn reject() -> u8 { return invalid_aggregate_params(.{ 1, 2 }, .{ 3, 4 }); }\n",
            ),
        ]
    )
    return cases


def run(mcc: str, source: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [mcc, "check", "-"],
        input=source,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )


def main() -> int:
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    try:
        accepted = run(mcc, accepted_source())
    except subprocess.TimeoutExpired:
        print("FAIL: numeric-comptime-matrix accepted cases timed out", file=sys.stderr)
        return 1
    if accepted.returncode != 0:
        print("FAIL: numeric-comptime-matrix accepted cases failed", file=sys.stderr)
        print(accepted.stderr, file=sys.stderr)
        return 1

    for marker, source in rejected_cases():
        try:
            rejected = run(mcc, source)
        except subprocess.TimeoutExpired:
            print(f"FAIL: numeric-comptime-matrix {marker} timed out", file=sys.stderr)
            return 1
        diagnostics = rejected.stderr.count("E_COMPTIME_TRAP")
        if rejected.returncode == 0 or diagnostics != 1 or marker not in rejected.stderr:
            print(
                f"FAIL: numeric-comptime-matrix {marker} expected one local E_COMPTIME_TRAP",
                file=sys.stderr,
            )
            print(rejected.stderr, file=sys.stderr)
            return 1

    print(
        "PASS: numeric-comptime-matrix — contextual typing, metadata transport, "
        "and checked/wrap/sat boundaries hold independently"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
