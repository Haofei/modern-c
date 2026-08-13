#!/usr/bin/env bash
# c-test gate, two phases over the tests/c_emit corpus:
#
#   1. PASS corpus  (tests/c_emit/*.mc) — every fixture must lower to C that clang accepts
#      under -std=c11 -Wall -Wextra -Werror.
#   2. REJECT corpus (tests/c_emit/bad/*.mc) — every fixture must be REJECTED by emit-c with
#      the diagnostic its `EXPECT: E_CODE` line names.
#
# The non-recursive `tests/c_emit/*.mc` glob naturally excludes bad/, so a reject fixture is
# never fed to the must-compile phase.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/lib/test-env.sh
. "$ROOT/tools/lib/test-env.sh"

exe="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
fixture_glob="${2:-tests/c_emit/*.mc}"
out_dir="${3:-zig-out/c-test}"
reject_glob="${4:-tests/c_emit/bad/*.mc}"
jobs="${JOBS:-$(mc_host_jobs)}"
case "$jobs" in
    ''|*[!0-9]*|0) echo "usage: JOBS must be a positive integer" >&2; exit 2 ;;
esac

mkdir -p "$out_dir"

# Phase 1 — must compile.
run_pass_fixture() {
    local exe="$1"
    local out_dir="$2"
    local fixture="$3"
    local base out err
    base=$(basename "$fixture" .mc)
    out="$out_dir/$base.c"
    err="$out_dir/$base.err"
    if ! "$exe" emit-c "$fixture" > "$out" 2>"$err"; then
        echo "FAIL: c-test — emit-c failed for $fixture" >&2
        cat "$err" >&2
        return 1
    fi
    if [ "$base" = "string_literals" ]; then
        grep -Fq '"tri\?\?/graph"' "$out" || {
            echo "FAIL: c-test — string_literals.mc did not escape '?' to avoid C trigraph spelling" >&2
            return 1
        }
        grep -Fq '"A\000B"' "$out" || {
            echo "FAIL: c-test — string_literals.mc did not emit canonical NUL escape spelling" >&2
            return 1
        }
        grep -Fq '.len = 3' "$out" || {
            echo "FAIL: c-test — string_literals.mc did not preserve decoded byte length for slice literal" >&2
            return 1
        }
        if grep -Fq '"tri??/graph"' "$out"; then
            echo "FAIL: c-test — string_literals.mc leaked raw trigraph spelling" >&2
            return 1
        fi
    fi
    clang -std=c11 -Wall -Wextra -Werror -fsyntax-only "$out"
}
export -f run_pass_fixture

pass_list="$out_dir/pass-fixtures.list"
: > "$pass_list"
for fixture in $fixture_glob; do
    printf '%s\n' "$fixture" >> "$pass_list"
done
pass=$(mc_count_lines "$pass_list")
if [ "$pass" -gt 0 ]; then
    xargs -P "$jobs" -n 1 bash -c 'run_pass_fixture "$0" "$1" "$2"' "$exe" "$out_dir" < "$pass_list"
fi

# Phase 2 — must be rejected with the named diagnostic.
run_reject_fixture() {
    local exe="$1"
    local fixture="$2"
    local want out rc
    [ -e "$fixture" ] || return 0   # no reject fixtures present -> nothing to assert
    want=$(grep -o 'EXPECT: [A-Z_]*' "$fixture" | awk '{print $2}')
    if [ -z "$want" ]; then
        echo "FAIL: c-test — $fixture has no 'EXPECT: E_CODE' line" >&2
        return 1
    fi
    # A reject fixture must FAIL emit-c (nonzero exit) AND name its diagnostic. Asserting
    # only on the message is spoofable: a fixture that COMPILES and merely emits a symbol or
    # comment containing the wanted code would otherwise count as "diagnosed". Require both —
    # capture the status explicitly (don't swallow it with `|| true`).
    set +e
    out=$("$exe" emit-c "$fixture" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: c-test — $fixture should have been REJECTED ($want) but emit-c succeeded (rc=0)" >&2
        printf '%s\n' "$out" | head >&2
        return 1
    fi
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL: c-test — $fixture rejected, but not with $want" >&2
        printf '%s\n' "$out" | head >&2
        return 1
    fi
}
export -f run_reject_fixture

reject_list="$out_dir/reject-fixtures.list"
: > "$reject_list"
for fixture in $reject_glob; do
    [ -e "$fixture" ] || continue
    printf '%s\n' "$fixture" >> "$reject_list"
done
reject=$(mc_count_lines "$reject_list")
if [ "$reject" -gt 0 ]; then
    xargs -P "$jobs" -n 1 bash -c 'run_reject_fixture "$0" "$1"' "$exe" < "$reject_list"
fi

echo "PASS: c-test — $pass fixtures compile; $reject reject fixtures diagnosed"
