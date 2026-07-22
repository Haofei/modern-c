#!/usr/bin/env bash
# Check-only comptime fold coverage (section 22) for the comptime-only value features that
# are not lowerable as runtime code — byte strings and wrap/sat arithmetic domains — so they
# cannot be exercised by the emit-swept tests/spec. Runs `mcc check` on a fixture whose true
# asserts must fold cleanly and whose four false asserts must each trap, and asserts EXACTLY
# four E_COMPTIME_TRAP: fewer means a fold was skipped (or a true assert wrongly trapped),
# more means a true assert produced the wrong value. Needs only mcc.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/comptime_fold.mc"

n="$("$MCC" check "$SRC" 2>&1 | grep -c 'E_COMPTIME_TRAP' || true)"
if [ "$n" -ne 4 ]; then
    echo "FAIL: comptime-fold-test — expected exactly 4 E_COMPTIME_TRAP (byte/wrap/sat folds), got $n"
    "$MCC" check "$SRC" 2>&1 | grep 'error:' | head
    exit 1
fi
echo "PASS: comptime-fold-test — byte-string and wrap/sat arithmetic-domain folds evaluate to the correct values"
