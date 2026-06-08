#!/usr/bin/env bash
# Sv39 page-table test: compile kernel/arch/riscv64/paging.mc (with std/addr +
# kernel/core/heap) to an object, link a C driver that builds a page table over a
# real pool, maps virtual->physical pages, and checks translation. Only the table
# frames (in the pool) are touched; the mapped targets are PTE values, not memory.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: paging-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/kernel/arch/riscv64/paging.mc" -o "$WORK/paging.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdbool.h>

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
    struct Heap h = heap_new(rng);
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

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/paging.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: paging-test — Sv39 map + translate (multi-level, shared interior tables, page offsets) computes correctly"
    exit 0
fi
echo "FAIL: paging-test — driver returned non-zero (failing CHECK line)"
exit 1
