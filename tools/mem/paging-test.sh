#!/usr/bin/env bash
# Sv39 page-table test: compile kernel/arch/riscv64/paging.mc through the
# selected backend, link a C driver that builds a page table over a real pool,
# maps virtual->physical pages, and checks translation. Only the table frames
# (in the pool) are touched; the mapped targets are PTE values, not memory.
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

case "$BACKEND" in
    c)
        MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/kernel/arch/riscv64/paging.mc" -o "$WORK/paging.o" >/dev/null
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/kernel/arch/riscv64/paging.mc" -o "$WORK/paging.o" >/dev/null
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        exit 2
        ;;
esac

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdbool.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

struct PhysRange { uintptr_t start; uintptr_t end; };
struct Heap { struct PhysRange range; uintptr_t next; };
struct PageTable { uintptr_t root; };
extern struct Heap heap_new(struct PhysRange r);
extern struct PageTable page_table_new(struct Heap *h);
extern void page_table_map(struct PageTable *pt, struct Heap *h, uintptr_t va, uintptr_t pa, uint64_t flags);
extern uintptr_t page_table_translate(struct PageTable *pt, uintptr_t va);
extern bool page_table_is_mapped(struct PageTable *pt, uintptr_t va);
extern void page_table_unmap(struct PageTable *pt, uintptr_t va);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
#define R 2u
#define W 4u
#define X 8u
static uint8_t pool[64 * 4096] __attribute__((aligned(4096)));

int main(void) {
    struct PhysRange rng = { (uintptr_t)pool, (uintptr_t)pool + sizeof(pool) };
#ifdef MC_LLVM_BACKEND
    // TODO: cover heap_new once LLVM aggregate-return ABI matches the C ABI.
    struct Heap h = { rng, rng.start };
#else
    struct Heap h = heap_new(rng);
#endif
    struct PageTable pt = page_table_new(&h);

    uintptr_t va = 0x10000000, pa = 0x80200000;
    page_table_map(&pt, &h, va, pa, R | W | X);
    CHECK(page_table_translate(&pt, va) == pa);
    CHECK(page_table_translate(&pt, va + 0x123) == pa + 0x123); // page offset preserved

    // A second mapping in a different top-level region (new interior tables).
    page_table_map(&pt, &h, 0x40000000, 0x80300000, R);
    CHECK(page_table_translate(&pt, 0x40000000) == 0x80300000);
    CHECK(page_table_translate(&pt, va) == pa); // first mapping still valid

    // An adjacent page in the same region (shares the interior tables).
    page_table_map(&pt, &h, va + 0x1000, pa + 0x5000, R | W);
    CHECK(page_table_translate(&pt, va + 0x1000) == pa + 0x5000);
    CHECK(page_table_translate(&pt, va) == pa);

    // Unmap one page; its neighbour (sharing interior tables) stays mapped.
    CHECK(page_table_is_mapped(&pt, va));
    page_table_unmap(&pt, va);
    CHECK(!page_table_is_mapped(&pt, va));
    CHECK(page_table_is_mapped(&pt, va + 0x1000));
    CHECK(page_table_translate(&pt, va + 0x1000) == pa + 0x5000);
    return 0;
}
EOF

DRIVER_CFLAGS=(-std=c11 -Wall -Wextra -Werror)
if [ "$BACKEND" = llvm ]; then
    DRIVER_CFLAGS+=(-DMC_LLVM_BACKEND=1)
fi
"$CLANG" "${DRIVER_CFLAGS[@]}" "$WORK/driver.c" "$WORK/paging.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend Sv39 map + translate (multi-level, shared interior tables, page offsets) computes correctly"
    exit 0
fi
echo "FAIL: $TEST_NAME — driver returned non-zero (failing CHECK line or signal, rc=$rc)"
exit 1
