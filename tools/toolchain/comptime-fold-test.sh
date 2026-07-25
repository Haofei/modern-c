#!/usr/bin/env bash
# Check-only comptime fold coverage (section 22) for the comptime-only value features that
# are not lowerable as runtime code — byte strings and wrap/sat arithmetic domains — so they
# cannot be exercised by the emit-swept tests/spec. Runs `mcc check` on a fixture whose true
# asserts must fold cleanly and whose adversarial false/checked cases must each trap, and
# asserts EXACTLY thirteen E_COMPTIME_TRAP: fewer means a fold was skipped,
# more means a true assert produced the wrong value. Needs only mcc.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/comptime_fold.mc"

n="$("$MCC" check "$SRC" 2>&1 | grep -c 'E_COMPTIME_TRAP' || true)"
if [ "$n" -ne 13 ]; then
    echo "FAIL: comptime-fold-test — expected exactly 13 E_COMPTIME_TRAP (numeric/domain folds), got $n"
    "$MCC" check "$SRC" 2>&1 | grep 'error:' | head
    exit 1
fi
echo "PASS: comptime-fold-test — width/domain/float/bitcast folds evaluate to the correct values"
