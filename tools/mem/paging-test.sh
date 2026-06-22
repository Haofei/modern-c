#!/usr/bin/env bash
# Sv39 page-table test: compile the MC driver (tests/mem/paging_host_driver.mc, which
# imports kernel/arch/riscv64/paging.mc) through the selected backend, link a tiny C
# harness that supplies a real physical pool + the trap/shadow stubs, and run it.
#
# The driver logic lives in MC, so there is NO C-side mirroring of the Heap/PageTable
# structs (whose layout drifts as the allocator/page-table evolve) — the C harness only
# sees `paging_host_test(pool_start, pool_len) -> u32`. The riscv `sfence.vma` inside
# paging.mc's `sfence_vma_page` is the one non-portable instruction; MC_STUB_ASM=1 lowers
# it to a host-neutral stub (a TLB fence is a no-op for this single-threaded host test),
# so the portable page-table math compiles and runs host-natively on any dev arch.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-paging-test" || echo "paging-test")
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (llc not found)"; exit 0; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DRIVER="$HERE/tests/mem/paging_host_driver.mc"
case "$BACKEND" in
    c)
        MC_STUB_ASM=1 MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$DRIVER" -o "$WORK/paging.o" >/dev/null
        ;;
    llvm)
        MC_STUB_ASM=1 MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$DRIVER" -o "$WORK/paging.o" >/dev/null
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        exit 2
        ;;
esac

cat >"$WORK/harness.c" <<'EOF'
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

/* KASAN shadow hooks: referenced by the heap's (never-taken) ksan branch in a default
   non-ksan heap, so they must link but are never called here. */
void mc_ksan_poison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }
void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }

extern uint32_t paging_host_test(uintptr_t pool_start, uintptr_t pool_len);

/* A page-aligned pool standing in for the physical region the page table carves its
   table frames from. 64 pages is ample for the handful of interior tables the checks
   build. */
static uint8_t pool[64 * 4096] __attribute__((aligned(4096)));

int main(void) {
    uint32_t rc = paging_host_test((uintptr_t)pool, sizeof(pool));
    return (int)rc; /* 0 = all checks passed; nonzero = id of the first failed check */
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/harness.c" "$WORK/paging.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend Sv39 map + translate (multi-level, shared interior tables, page offsets) computes correctly"
    exit 0
fi
echo "FAIL: $TEST_NAME — driver returned non-zero (failed check id or signal, rc=$rc)"
exit 1
