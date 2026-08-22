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

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/opt_bounds.mc"
NEG="$HERE/tests/toolchain/opt_bounds_neg.mc"

# `lower-mir` exposes the verified MIR boundary, so it correctly refuses the
# deliberately-invalid #[no_lang_trap] fixtures before printing a dump. Keep
# those originals for the contract admission assertions, and inspect otherwise
# identical stdin probes with only the contract attribute removed. Capture each
# dump once both to avoid repeated compiler startup and to avoid pipefail/SIGPIPE
# false negatives from piping a large dump through `grep -q`.
SRC_PROBE="$(sed '/^#\[no_lang_trap\]$/d' "$SRC")"
NEG_PROBE="$(sed '/^#\[no_lang_trap\]$/d' "$NEG")"
MIR_UNOPT="$("$MCC" lower-mir - 2>/dev/null <<<"$SRC_PROBE")"
MIR_OPT="$("$MCC" lower-mir - --optimize 2>/dev/null <<<"$SRC_PROBE")"
MIR_NEG_OPT="$("$MCC" lower-mir - --optimize 2>/dev/null <<<"$NEG_PROBE")"

# 1. Without --optimize the contract is rejected and the Bounds trap edge is present.
if "$MCC" verify "$SRC" >/dev/null 2>&1; then
    echo "FAIL: opt-test — const-index #[no_lang_trap] was accepted without --optimize"; exit 1
fi
if ! grep -q 'kind=Bounds' <<<"$MIR_UNOPT"; then
    echo "FAIL: opt-test — expected a Bounds trap edge in the unoptimized MIR"; exit 1
fi

# 2. With --optimize the contract holds and the Bounds trap edge is gone.
if ! "$MCC" verify "$SRC" --optimize >/dev/null 2>&1; then
    echo "FAIL: opt-test — const-index #[no_lang_trap] was rejected under --optimize"
    "$MCC" verify "$SRC" --optimize 2>&1 | head
    exit 1
fi
if grep -q 'kind=Bounds' <<<"$MIR_OPT"; then
    echo "FAIL: opt-test — a Bounds trap edge survived const-index elision under --optimize"; exit 1
fi
if ! grep -q 'detail=const_in_bounds' <<<"$MIR_OPT"; then
    echo "FAIL: opt-test — elided index not marked const_in_bounds under --optimize"; exit 1
fi

# 2c. Const-slice elision: the `const_slice` range provably can't trap, so under --optimize the
#     slice is marked range_slice_const_in_bounds (unoptimized it is a plain range_slice and the
#     Bounds edge above covers its trap edge).
if ! grep -q 'detail=range_slice ' <<<"$MIR_UNOPT"; then
    echo "FAIL: opt-test — expected a plain range_slice in the unoptimized MIR"; exit 1
fi
if ! grep -q 'detail=range_slice_const_in_bounds' <<<"$MIR_OPT"; then
    echo "FAIL: opt-test — const-slice not marked range_slice_const_in_bounds under --optimize"; exit 1
fi

# 2b. Divide-by-constant elision: the DivideByZero (and the signed INT_MIN/-1 overflow) edge
#     is present unoptimized and gone under --optimize.
if ! grep -q 'kind=DivideByZero' <<<"$MIR_UNOPT"; then
    echo "FAIL: opt-test — expected a DivideByZero trap edge in the unoptimized MIR"; exit 1
fi
if grep -qE 'kind=(DivideByZero|IntegerOverflow)' <<<"$MIR_OPT"; then
    echo "FAIL: opt-test — a DivideByZero/IntegerOverflow trap edge survived div-by-constant elision under --optimize"; exit 1
fi

# 3. Operations not provably safe — a variable index, a variable divisor, and signed `/ -1`
#    (the INT_MIN/-1 overflow case) — keep their checks, so the contract stays rejected.
if "$MCC" verify "$NEG" --optimize >/dev/null 2>&1; then
    echo "FAIL: opt-test — a non-provable #[no_lang_trap] op (variable index/divisor or signed / -1) was accepted under --optimize"; exit 1
fi
if ! grep -q 'kind=IntegerOverflow' <<<"$MIR_NEG_OPT"; then
    echo "FAIL: opt-test — signed / -1 lost its IntegerOverflow trap edge under --optimize"; exit 1
fi
# The out-of-range constant slice (`gbuf[1..9]`, end 9 > len 8) must keep its Bounds edge — the
# const-slice elision must never prove an out-of-bounds range safe.
if ! grep -q 'kind=Bounds' <<<"$MIR_NEG_OPT"; then
    echo "FAIL: opt-test — an out-of-range const slice lost its Bounds trap edge under --optimize"; exit 1
fi

# 4. Range-fact elision (annex E 3.4): a runtime index/divisor proven safe by an `if`/`while`
#    guard has its trap edge dropped under --optimize, while operations the analysis cannot prove
#    keep theirs. Uses lower-mir per function (the guard forms are broader than the #[no_lang_trap]
#    contract surface, so this asserts the MIR trap edges directly rather than via `verify`).
GUARD="$HERE/tests/toolchain/opt_guard.mc"

# edge_present <fn> <kind> <optflag> -> 0 if a matching trap edge exists, 1 otherwise
edge_present() {
    "$MCC" lower-mir "$GUARD" $3 2>/dev/null | grep -qE "trap_edge fn=$1 .*kind=$2"
}

# Positives: the guard proves the op safe, so under --optimize the edge is GONE (present without).
for pair in "guarded_index:Bounds" "while_index:Bounds" "guarded_div:DivideByZero" \
            "guarded_signed_div:DivideByZero" "guarded_signed_div:IntegerOverflow"; do
    fn="${pair%%:*}"; kind="${pair#*:}"
    edge_present "$fn" "$kind" ""          || { echo "FAIL: opt-test — $fn lost its $kind edge WITHOUT --optimize"; exit 1; }
    edge_present "$fn" "$kind" "--optimize" && { echo "FAIL: opt-test — $fn kept its $kind edge under --optimize (guard fact not applied)"; exit 1; }
done

# Negatives: unprovable, so the edge must REMAIN even under --optimize (soundness floor: a
# too-weak bound, a signed divisor that could be -1, an address-taken index, a re-assigned index).
for pair in "wrong_bound:Bounds" "signed_div_ne:DivideByZero" "signed_div_ne:IntegerOverflow" \
            "aliased_index:Bounds" "mutated_index:Bounds"; do
    fn="${pair%%:*}"; kind="${pair#*:}"
    edge_present "$fn" "$kind" "--optimize" || { echo "FAIL: opt-test — $fn wrongly dropped its $kind edge under --optimize (unsound elision)"; exit 1; }
done

echo "PASS: opt-test — const-index/const-slice bounds and divide-by-constant check elision proven, gated by --optimize, sound on variable/out-of-range/-1 operands; range-fact (guard/while) index+divisor elision proven, sound on weak-bound/signed-/-1/address-taken/re-assigned operands"
