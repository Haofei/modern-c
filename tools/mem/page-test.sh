#!/usr/bin/env bash
# Page/frame allocator test: compile kernel/core/page_alloc.mc through the
# selected backend, link a C driver that exercises bump allocation, free-list
# reclaim, and LIFO reuse over a real backing pool, and run it.
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
        MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/kernel/core/page_alloc.mc" -o "$WORK/page_alloc.o" >/dev/null
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/kernel/core/page_alloc.mc" -o "$WORK/page_alloc.o" >/dev/null
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

// The opaque address class PAddr and the move handle Page lower to plain words;
// only the struct *layout* matters for the ABI (the type names are erased).
struct Page { uintptr_t addr; };
struct PhysRange { uintptr_t start; uintptr_t end; };
typedef struct { struct PhysRange range; } MemoryMapU;
typedef struct { struct PhysRange range; } MemoryMapV;
struct PageAllocator { uintptr_t next, end, free_head, free_count; };

extern MemoryMapU memory_map(uintptr_t base, uintptr_t size);
extern MemoryMapV validate(MemoryMapU m);
extern struct PageAllocator page_allocator_from(MemoryMapV m);
extern struct Page page_alloc(struct PageAllocator *a);
extern void page_free(struct PageAllocator *a, struct Page p);
extern uintptr_t page_addr(struct Page *p);
extern uintptr_t pages_available(struct PageAllocator *a);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
#define PAGE 4096u
static uint8_t pool[16 * PAGE] __attribute__((aligned(PAGE)));

int main(void) {
    uintptr_t base = (uintptr_t)pool;
    struct PageAllocator a = page_allocator_from(validate(memory_map(base, sizeof(pool))));
    CHECK(pages_available(&a) == 16);

    // Bump allocation hands out consecutive frames.
    struct Page p0 = page_alloc(&a); CHECK(page_addr(&p0) == base);
    struct Page p1 = page_alloc(&a); CHECK(page_addr(&p1) == base + PAGE);
    struct Page p2 = page_alloc(&a); CHECK(page_addr(&p2) == base + 2 * PAGE);
    CHECK(pages_available(&a) == 13);

    // Free returns the frame; the next alloc reuses it (real reclaim, not a leak).
    page_free(&a, p1);
    CHECK(pages_available(&a) == 14);
    struct Page r = page_alloc(&a); CHECK(page_addr(&r) == base + PAGE);
    CHECK(pages_available(&a) == 13);

    // LIFO free list: the most-recently-freed frame is handed out first.
    page_free(&a, p0); // head -> p0
    page_free(&a, p2); // head -> p2
    struct Page x = page_alloc(&a); CHECK(page_addr(&x) == base + 2 * PAGE); // p2
    struct Page y = page_alloc(&a); CHECK(page_addr(&y) == base);            // p0
    CHECK(pages_available(&a) == 13);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/page_alloc.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend frame allocator bump + free-list reclaim + LIFO reuse compute correctly"
    exit 0
fi
echo "FAIL: $TEST_NAME — driver returned non-zero (failing CHECK line or signal, rc=$rc)"
exit 1
