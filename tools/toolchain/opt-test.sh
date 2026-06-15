#!/usr/bin/env bash
# Fact-gated MIR optimizer test (annex E): const-index bounds-check elision. Validates the
# first optimizer transform end to end through `mcc`, with no external toolchain needed:
#   1. Default (no --optimize): the #[no_lang_trap] const-index module is REJECTED, and its
#      MIR carries a `Bounds` trap edge — the standard pipeline is unchanged.
#   2. --optimize: the same module is ACCEPTED and its MIR has NO `Bounds` trap edge — the
#      provably-in-range constant index proved the check dead and elided it.
#   3. Soundness floor: a variable (non-constant) index stays REJECTED even under --optimize,
#      so the elision never fires on an index it cannot prove in range.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/opt_bounds.mc"
NEG="$HERE/tests/toolchain/opt_bounds_neg.mc"

# 1. Without --optimize the contract is rejected and the Bounds trap edge is present.
if "$MCC" verify "$SRC" >/dev/null 2>&1; then
    echo "FAIL: opt-test — const-index #[no_lang_trap] was accepted without --optimize"; exit 1
fi
if ! "$MCC" lower-mir "$SRC" 2>/dev/null | grep -q 'kind=Bounds'; then
    echo "FAIL: opt-test — expected a Bounds trap edge in the unoptimized MIR"; exit 1
fi

# 2. With --optimize the contract holds and the Bounds trap edge is gone.
if ! "$MCC" verify "$SRC" --optimize >/dev/null 2>&1; then
    echo "FAIL: opt-test — const-index #[no_lang_trap] was rejected under --optimize"
    "$MCC" verify "$SRC" --optimize 2>&1 | head
    exit 1
fi
if "$MCC" lower-mir "$SRC" --optimize 2>/dev/null | grep -q 'kind=Bounds'; then
    echo "FAIL: opt-test — a Bounds trap edge survived const-index elision under --optimize"; exit 1
fi
if ! "$MCC" lower-mir "$SRC" --optimize 2>/dev/null | grep -q 'detail=const_in_bounds'; then
    echo "FAIL: opt-test — elided index not marked const_in_bounds under --optimize"; exit 1
fi

# 2b. Divide-by-constant elision: the DivideByZero (and the signed INT_MIN/-1 overflow) edge
#     is present unoptimized and gone under --optimize.
if ! "$MCC" lower-mir "$SRC" 2>/dev/null | grep -q 'kind=DivideByZero'; then
    echo "FAIL: opt-test — expected a DivideByZero trap edge in the unoptimized MIR"; exit 1
fi
if "$MCC" lower-mir "$SRC" --optimize 2>/dev/null | grep -qE 'kind=(DivideByZero|IntegerOverflow)'; then
    echo "FAIL: opt-test — a DivideByZero/IntegerOverflow trap edge survived div-by-constant elision under --optimize"; exit 1
fi

# 3. Operations not provably safe — a variable index, a variable divisor, and signed `/ -1`
#    (the INT_MIN/-1 overflow case) — keep their checks, so the contract stays rejected.
if "$MCC" verify "$NEG" --optimize >/dev/null 2>&1; then
    echo "FAIL: opt-test — a non-provable #[no_lang_trap] op (variable index/divisor or signed / -1) was accepted under --optimize"; exit 1
fi
if ! "$MCC" lower-mir "$NEG" --optimize 2>/dev/null | grep -q 'kind=IntegerOverflow'; then
    echo "FAIL: opt-test — signed / -1 lost its IntegerOverflow trap edge under --optimize"; exit 1
fi

echo "PASS: opt-test — const-index bounds and divide-by-constant check elision proven, gated by --optimize, sound on variable/-1 operands"
