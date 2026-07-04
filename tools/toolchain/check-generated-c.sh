#!/bin/sh
# c-test gate, two phases over the tests/c_emit corpus:
#
#   1. PASS corpus  (tests/c_emit/*.mc) — every fixture must lower to C that clang accepts
#      under -std=c11 -Wall -Wextra -Werror.
#   2. REJECT corpus (tests/c_emit/bad/*.mc) — every fixture must be REJECTED by emit-c with
#      the diagnostic its `EXPECT: E_CODE` line names. This mirrors the kernel/bad/ convention
#      that kernel-test.sh already uses, so the two suites share one reject contract.
#
# The non-recursive `tests/c_emit/*.mc` glob naturally excludes bad/, so a reject fixture is
# never fed to the must-compile phase.
set -eu

exe="${1:-zig-out/bin/mcc}"
fixture_glob="${2:-tests/c_emit/*.mc}"
out_dir="${3:-zig-out/c-test}"
reject_glob="${4:-tests/c_emit/bad/*.mc}"

mkdir -p "$out_dir"

# Phase 1 — must compile.
pass=0
for fixture in $fixture_glob; do
    base=$(basename "$fixture" .mc)
    out="$out_dir/$base.c"
    err="$out_dir/$base.err"
    if ! "$exe" emit-c "$fixture" > "$out" 2>"$err"; then
        echo "FAIL: c-test — emit-c failed for $fixture" >&2
        cat "$err" >&2
        exit 1
    fi
    if [ "$base" = "string_literals" ]; then
        grep -Fq '"tri\?\?/graph"' "$out" || {
            echo "FAIL: c-test — string_literals.mc did not escape '?' to avoid C trigraph spelling" >&2
            exit 1
        }
        grep -Fq '"A\000B"' "$out" || {
            echo "FAIL: c-test — string_literals.mc did not emit canonical NUL escape spelling" >&2
            exit 1
        }
        grep -Fq '.len = 3' "$out" || {
            echo "FAIL: c-test — string_literals.mc did not preserve decoded byte length for slice literal" >&2
            exit 1
        }
        if grep -Fq '"tri??/graph"' "$out"; then
            echo "FAIL: c-test — string_literals.mc leaked raw trigraph spelling" >&2
            exit 1
        fi
    fi
    clang -std=c11 -Wall -Wextra -Werror -fsyntax-only "$out"
    pass=$((pass + 1))
done

# Phase 2 — must be rejected with the named diagnostic.
reject=0
for fixture in $reject_glob; do
    [ -e "$fixture" ] || continue   # no reject fixtures present -> nothing to assert
    want=$(grep -o 'EXPECT: [A-Z_]*' "$fixture" | awk '{print $2}')
    if [ -z "$want" ]; then
        echo "FAIL: c-test — $fixture has no 'EXPECT: E_CODE' line" >&2
        exit 1
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
        exit 1
    fi
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL: c-test — $fixture rejected, but not with $want" >&2
        printf '%s\n' "$out" | head >&2
        exit 1
    fi
    reject=$((reject + 1))
done

echo "PASS: c-test — $pass fixtures compile; $reject reject fixtures diagnosed"
