#!/usr/bin/env bash
# Page/frame allocator test: compile the MC host driver (tests/mem/page_host_driver.mc,
# which imports kernel/core/page_alloc.mc) through the selected backend, link a
# MINIMAL C harness, and run it. The whole test body lives in MC — the C harness
# mirrors NO MC struct (PageAllocator, Page, MemoryMap, PhysRange), so the silent
# by-value/sret ABI drift that bit the paging test cannot happen here. The harness
# supplies only the trap stubs, a page-aligned backing pool, and main().
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-page-test" || echo "page-test")
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (llc not found)"; exit 0; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$BACKEND" in
    c)
        MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/mem/page_host_driver.mc" -o "$WORK/driver_mc.o" >/dev/null
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/mem/page_host_driver.mc" -o "$WORK/driver_mc.o" >/dev/null
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        exit 2
        ;;
esac

cat >"$WORK/harness.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

// The entire test is in MC. The harness mirrors no MC type: it only passes the
// pool's raw base/length (plain words) and reads back a u32 result code.
extern uint32_t page_host_test(uintptr_t pool_start, uintptr_t pool_len);

#define PAGE 4096u
static uint8_t pool[16 * PAGE] __attribute__((aligned(PAGE)));

int main(void) {
    return (int)page_host_test((uintptr_t)pool, sizeof(pool));
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/harness.c" "$WORK/driver_mc.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend frame allocator bump + free-list reclaim + LIFO reuse compute correctly"
    exit 0
fi
echo "FAIL: $TEST_NAME — MC driver returned non-zero (failing check id or signal, rc=$rc)"
exit 1
