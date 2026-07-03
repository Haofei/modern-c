#!/usr/bin/env bash
# LLVM demo-driver object gate: compile the demos that are in the current LLVM
# backend surface to non-empty objects through llc.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
LLC="${LLC:-llc}"
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-demo-test (llc not found)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: llvm-demo-test (python3 not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

demos=(
    "demo/framebuffer/framebuffer.mc"
    "demo/gpio/gpio.mc"
    "demo/irq/irq.mc"
    "demo/spi/spi.mc"
    "demo/timer/timer.mc"
    "demo/uart/uart.mc"
    "demo/hosted/elementwise.mc"
)

count=0
for rel in "${demos[@]}"; do
    src="$HERE/$rel"
    ll="$WORK/${rel//\//_}.ll"
    out="$WORK/${rel//\//_}.o"
    if ! "$MCC" emit-llvm "$src" >"$ll" 2>"$WORK/err"; then
        echo "FAIL: llvm-demo-test - $rel did not compile through LLVM"
        cat "$WORK/err"
        exit 1
    fi
    if ! python3 - "$ll" "$src" <<'PY'; then
import re
import sys

ll_path, src_path = sys.argv[1], sys.argv[2]
source = open(src_path, encoding="utf-8").read()
token_re = re.compile(r"(^|[ ,(])({})([ ,)]|$)".format("|".join(
    re.escape(t) for t in (
        "nuw", "nsw", "nonnull", "noalias", "noundef", "poison", "inbounds",
        "undef", "fast", "nnan", "ninf", "nsz", "arcp", "contract", "afn",
    )
)))
reassoc_re = re.compile(r"(^|[ ,(])reassoc([ ,)]|$)")
for line_no, line in enumerate(open(ll_path, encoding="utf-8"), 1):
    match = token_re.search(line)
    if match:
        print(f"forbidden LLVM assumption token '{match.group(2)}' at line {line_no}: {line.strip()}", file=sys.stderr)
        sys.exit(1)
    if reassoc_re.search(line) and not ("fadd reassoc" in line and "reduce.sum_fast" in source):
        print(f"forbidden LLVM assumption token 'reassoc' at line {line_no}: {line.strip()}", file=sys.stderr)
        sys.exit(1)
PY
        echo "FAIL: llvm-demo-test - $rel emitted a hidden optimizer assumption"
        exit 1
    fi
    if ! "$LLC" -filetype=obj "$ll" -o "$out" 2>"$WORK/err"; then
        echo "FAIL: llvm-demo-test - $rel did not compile to an LLVM object"
        cat "$WORK/err"
        exit 1
    fi
    if [ ! -s "$out" ]; then
        echo "FAIL: llvm-demo-test - $rel produced an empty object"
        exit 1
    fi
    count=$((count + 1))
done

echo "PASS: llvm-demo-test - $count demo drivers compiled to LLVM objects"
