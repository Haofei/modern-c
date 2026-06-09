#!/usr/bin/env bash
# demo/hosted/run.sh — the full hosted-profile data round-trip:
#   MC  --(mcc emit-c --profile=hosted)-->  C  --(clang -lm)-->  native exe
#   then feed it a binary float buffer on stdin and verify the bytes it writes.
#
# This is the exact pipeline a separate frontend uses: it produces the stdin
# wire format (u32 N, f32 a[N], f32 b[N]), runs the kernel, and consumes the
# stdout f32 result. The kernel computes out[i] = sqrt(a[i]) + b[i].
#
# Usage: demo/hosted/run.sh [path-to-mcc]
# Self-skips (exit 0) when clang or python3 is unavailable, like the other demos.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(d="$HERE"; while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MCC="${1:-$ROOT/zig-out/bin/mcc}"
CLANG="${CLANG:-clang}"

command -v "$CLANG"  >/dev/null 2>&1 || { echo "SKIP: hosted-demo (clang not found)";   exit 0; }
command -v python3   >/dev/null 2>&1 || { echo "SKIP: hosted-demo (python3 not found)"; exit 0; }
[ -x "$MCC" ] || { echo "FAIL: hosted-demo — mcc not built at $MCC (run: zig build)"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. MC -> C (hosted profile) -> native executable, linking libc + libm (-lm).
"$MCC" emit-c "$HERE/elementwise.mc" --profile=hosted > "$WORK/kernel.c"
"$CLANG" -std=c11 -Wall -Wextra "$WORK/kernel.c" "$HERE/main.c" -lm -o "$WORK/kernel"

# 2. Produce the input buffer and the expected output, run, and diff.
python3 - "$WORK" <<'PY'
import os, struct, subprocess, sys, math
work = sys.argv[1]
a = [4.0, 9.0, 16.0, 0.25, 100.0]
b = [1.0, 2.0,  3.0, 0.75,  -5.0]
n = len(a)
stdin  = struct.pack("<I", n) + b"".join(struct.pack("<f", x) for x in a) \
                              + b"".join(struct.pack("<f", x) for x in b)
expect = [math.sqrt(struct.unpack("<f", struct.pack("<f", x))[0])
          + struct.unpack("<f", struct.pack("<f", y))[0] for x, y in zip(a, b)]

p = subprocess.run([os.path.join(work, "kernel")], input=stdin, capture_output=True)
if p.returncode != 0:
    print(f"FAIL: hosted-demo — kernel exited {p.returncode}"); sys.exit(1)

out = [struct.unpack("<f", p.stdout[i:i+4])[0] for i in range(0, len(p.stdout), 4)]
if len(out) != n:
    print(f"FAIL: hosted-demo — got {len(out)} results, want {n}"); sys.exit(1)
for got, want in zip(out, expect):
    # f32 round-trip: compare in float32 precision.
    want32 = struct.unpack("<f", struct.pack("<f", want))[0]
    if abs(got - want32) > 1e-5 * (1 + abs(want32)):
        print(f"FAIL: hosted-demo — got {out}, want {expect}"); sys.exit(1)
print(f"observed output: {out}")
print("PASS: hosted-demo — sqrt(a)+b round-trip through stdin/stdout matches")
PY
