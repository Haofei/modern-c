#!/usr/bin/env bash
# Hosted demo run gate through the LLVM backend: compile the MC hosted
# elementwise kernel to an object with llc, link it with libc/libm and trap
# stubs, then verify the stdin/stdout f32 round trip.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: llvm-hosted-demo-test (clang not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-hosted-demo-test (llc not found)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: llvm-hosted-demo-test (python3 not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/demo/hosted/elementwise.mc" -o "$WORK/kernel.o" >/dev/null

cat >"$WORK/driver.c" <<'CEOF'
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

extern int32_t hosted_kernel_run(void);

int main(void) {
    return hosted_kernel_run();
}
CEOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/kernel.o" -lm -o "$WORK/kernel"

python3 - "$WORK" <<'PY'
import math
import os
import struct
import subprocess
import sys

work = sys.argv[1]
a = [4.0, 9.0, 16.0, 0.25, 100.0]
b = [1.0, 2.0, 3.0, 0.75, -5.0]
n = len(a)
stdin = (
    struct.pack("<I", n)
    + b"".join(struct.pack("<f", x) for x in a)
    + b"".join(struct.pack("<f", x) for x in b)
)
expect = [
    math.sqrt(struct.unpack("<f", struct.pack("<f", x))[0])
    + struct.unpack("<f", struct.pack("<f", y))[0]
    for x, y in zip(a, b)
]

p = subprocess.run([os.path.join(work, "kernel")], input=stdin, capture_output=True)
if p.returncode != 0:
    print(f"FAIL: llvm-hosted-demo-test - kernel exited {p.returncode}")
    sys.exit(1)

out = [struct.unpack("<f", p.stdout[i : i + 4])[0] for i in range(0, len(p.stdout), 4)]
if len(out) != n:
    print(f"FAIL: llvm-hosted-demo-test - got {len(out)} results, want {n}")
    sys.exit(1)
for got, want in zip(out, expect):
    want32 = struct.unpack("<f", struct.pack("<f", want))[0]
    if abs(got - want32) > 1e-5 * (1 + abs(want32)):
        print(f"FAIL: llvm-hosted-demo-test - got {out}, want {expect}")
        sys.exit(1)
PY

echo "PASS: llvm-hosted-demo-test - hosted elementwise demo lowered through LLVM, linked, and ran"
