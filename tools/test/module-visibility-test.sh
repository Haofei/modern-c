#!/usr/bin/env bash
# Opt-in module visibility (`pub`, §30). A module that marks its public surface with `pub`
# becomes "strict": its `pub`/`export` items are reachable across files, its other items are
# private to it. This gate checks BOTH directions on the selected backend:
#   allow  modvis_use.mc imports modvis_lib.mc and uses ONLY its `pub` API -> compiles, and
#          its #[test]s pass (run process-isolated by the shared test runner).
#   deny   modvis_deny.mc references a PRIVATE item across the file boundary -> the compile
#          MUST fail with E_PRIVATE_IMPORT (and emit no object).
#
# Usage: tools/test/module-visibility-test.sh <path-to-mcc> <c|llvm>
# Skips (exit 0) when clang/llc is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
NAME=$([ "$BACKEND" = llvm ] && echo "llvm-mod-visibility-test" || echo "mod-visibility-test")

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $NAME (llc not found)"; exit 0; }
fi

fail=0

# --- allow: the public-API consumer compiles and its #[test]s pass ---
if ! bash "$HERE/tools/test/mc-test-runner.sh" "$MCC" "$BACKEND" "$HERE/tests/test/modvis_use.mc" >/tmp/modvis_allow.$$ 2>&1; then
    echo "FAIL: $NAME — public-API consumer (modvis_use.mc) did not pass:"
    sed 's/^/  /' /tmp/modvis_allow.$$
    fail=1
else
    echo "ok   allow: modvis_use.mc uses modvis_lib's pub API ($BACKEND)"
fi
rm -f /tmp/modvis_allow.$$

# --- deny: referencing a private item across files must fail with E_PRIVATE_IMPORT ---
if [ "$BACKEND" = llvm ]; then SCRIPT=mcc-llvm-cc.sh; else SCRIPT=mcc-cc.sh; fi
deny_out="$(MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" bash "$HERE/tools/toolchain/$SCRIPT" "$HERE/tests/test/modvis_deny.mc" -o /tmp/modvis_deny.$$.o 2>&1 || true)"
if printf '%s' "$deny_out" | grep -q "E_PRIVATE_IMPORT"; then
    echo "ok   deny:  modvis_deny.mc cross-file private use -> E_PRIVATE_IMPORT ($BACKEND)"
else
    echo "FAIL: $NAME — private cross-file use was NOT rejected with E_PRIVATE_IMPORT"
    printf '%s\n' "$deny_out" | sed 's/^/  /' | head -5
    fail=1
fi
rm -f /tmp/modvis_deny.$$.o

if [ "$fail" -eq 0 ]; then
    echo "PASS: $NAME — pub surface reachable across files; private items rejected ($BACKEND backend)"
    exit 0
fi
echo "FAIL: $NAME"
exit 1
