#!/usr/bin/env bash
# c-test gate, two phases over the tests/c_emit corpus:
#
#   1. PASS corpus  (tests/c_emit/*.mc) — every fixture must lower to C that clang accepts
#      under -std=c11 -Wall -Wextra -Werror.
#   2. REJECT corpus (tests/c_emit/bad/*.mc) — every fixture must be REJECTED by emit-c with
#      the diagnostic its `EXPECT: E_CODE` line names.
#   3. KNOWN-FAILING corpus (docs/backend-expected-failures.json) — fixtures the C backend
#      cannot compile today. They are held out of phase 1 but still asserted: each must fail,
#      and fail for its recorded reason. A known-failing fixture that starts passing, or fails
#      for a different reason, fails the gate — so the list can only shrink deliberately, and a
#      NEW failure is never mistaken for standing debt.
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

expected_manifest="$ROOT/docs/backend-expected-failures.json"
known_list="$out_dir/known-failing.list"
# The needle each known-failing fixture must still fail with. `E_BACKEND_UNSUPPORTED`
# is the backend's single refusal code, so an entry carrying it records a structured
# `cause` as well and the needle is the whole rendered diagnostic -- the refusing
# phase, category, construct and function -- not just the code. A fixture that drifts
# to a different gap then fails this gate instead of resting on the old entry.
python3 - "$expected_manifest" "$ROOT/tools/toolchain" > "$known_list" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
from backend_gap_lib import render_cause
manifest = json.load(open(sys.argv[1]))
for entry in manifest["emit_c"]:
    cause = entry.get("cause")
    print(entry["fixture"] + "\t" + (render_cause(cause) if cause else entry["reason"]))
PY

is_known_failing() {
    cut -f1 < "$known_list" | grep -Fxq "$1"
}

pass_list="$out_dir/pass-fixtures.list"
: > "$pass_list"
for fixture in $fixture_glob; do
    is_known_failing "$fixture" && continue
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

# Phase 3 — known-failing fixtures must still fail, for their recorded reason.
run_known_fixture() {
    local exe="$1"
    local fixture="$2"
    local want="$3"
    local out rc
    if [ ! -e "$fixture" ]; then
        echo "FAIL: c-test — docs/backend-expected-failures.json names missing fixture $fixture" >&2
        return 1
    fi
    set +e
    out=$("$exe" emit-c "$fixture" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: c-test — $fixture is listed as known-failing but emit-c now succeeds; remove its entry from docs/backend-expected-failures.json" >&2
        return 1
    fi
    if [ -z "$out" ]; then
        echo "FAIL: c-test — $fixture failed with no diagnostic at all" >&2
        return 1
    fi
    # -F: a recorded cause is a whole rendered diagnostic, not a regex.
    if ! printf '%s' "$out" | grep -Fq "$want"; then
        echo "FAIL: c-test — $fixture no longer fails with $want; update docs/backend-expected-failures.json" >&2
        printf '%s\n' "$out" | head >&2
        return 1
    fi
}
export -f run_known_fixture

known=$(mc_count_lines "$known_list")
if [ "$known" -gt 0 ]; then
    # NUL-delimited: a recorded cause is a rendered diagnostic with spaces in it,
    # so whitespace must not split one needle into several arguments.
    tr '\t\n' '\0\0' < "$known_list" | xargs -0 -P "$jobs" -n 2 bash -c 'run_known_fixture "$0" "$1" "$2"' "$exe"
fi

echo "PASS: c-test — $pass fixtures compile; $reject reject fixtures diagnosed; $known known-failing fixtures still fail for their recorded reason"
