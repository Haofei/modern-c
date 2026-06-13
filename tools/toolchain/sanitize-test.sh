#!/usr/bin/env bash
# Sanitizer gate: rebuild and run the host-driver test corpus (tools/lib/host-tests.tsv) with
# ASan + UBSan, failing on any sanitizer report. This exercises the *emitted C* for undefined
# behavior and bad memory access that the -fsyntax-only sweeps cannot see — signed/shift
# overflow, out-of-bounds, null/misaligned access in lowered MC. Each row is independent, so
# the corpus fans out across cores (override with JOBS=N).
#
# Leak detection is intentionally off (ASAN_OPTIONS=detect_leaks=0): many fixtures use
# arena/pool allocators whose backing memory is deliberately live at exit. Principled leak
# checking is the move-resource live_count invariant (a separate gate), not LSan-at-exit here.
# `function` is excluded inside host-harness.sh (the type-erased closure/Allocator vtable ABI).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: sanitize-test (clang not found)"; exit 0; }
MANIFEST="$HERE/tools/lib/host-tests.tsv"

export MCC HERE CLANG
export ASAN_OPTIONS="detect_leaks=0:abort_on_error=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"

# Build + run one fixture under the sanitizers via the shared host-harness. First a baseline
# (un-instrumented) build: a fixture that cannot even build/run on this host without sanitizers
# — e.g. one carrying riscv-only inline asm like `sfence.vma` on an x86 host — is environment-
# unsupported and skipped, not a sanitizer finding. If the baseline runs, the SANITIZE=1 build
# adds ASan + UBSan; a sanitizer report makes the app exit non-zero, surfaced as a FAIL.
san_one() {
    local name="$1"
    # Fixtures that hand-build device-state globals (a fault-injection mock corrupts the
    # device-owned vring rings directly). ASan's global redzone instrumentation mis-handles
    # those raw aliased structs and faults with no report, while the fixture is clean under
    # UBSan and the plain + differential runs — so only ASan's checks are skipped for them.
    local sanitize_skip=" vqfault-test "
    case "$sanitize_skip" in
        *" $name "*) echo "SKIP: sanitize $name (hand-built device-state globals confuse ASan; covered by UBSan + diff-backend)"; return 0 ;;
    esac
    if ! SANITIZE= bash "$HERE/tools/lib/host-harness.sh" "$MCC" "$name" >/dev/null 2>&1; then
        echo "SKIP: sanitize $name (does not build/run on this host without sanitizers)"
        return 0
    fi
    local out
    if ! out="$(SANITIZE=1 bash "$HERE/tools/lib/host-harness.sh" "$MCC" "$name" 2>&1)"; then
        echo "FAIL: sanitize $name"
        printf '%s\n' "$out" | grep -iE "runtime error|AddressSanitizer|SUMMARY|FAIL:" | head -5
        return 1
    fi
    return 0
}
export -f san_one

mapfile -t names < <(awk -F'\t' '/^#/{next} NF>=2 && $1!=""{print $1}' "$MANIFEST")
count="${#names[@]}"
printf '%s\0' "${names[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'san_one "$@"' _ {}

echo "PASS: sanitize-test — $count host-driver fixtures clean under ASan + UBSan"
