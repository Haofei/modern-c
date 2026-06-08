#!/usr/bin/env bash
# Kernel heap test: compile kernel/core/heap.mc (with its std/addr import) to an
# object, link a C driver that exercises aligned bump allocation over a real pool,
# and run it.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: heap-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/kernel/core/heap.mc" -o "$WORK/heap.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

struct PhysRange { uintptr_t start; uintptr_t end; };
struct Heap { struct PhysRange range; uintptr_t next; };
extern struct Heap heap_new(struct PhysRange r);
extern uintptr_t heap_alloc(struct Heap *h, uintptr_t size, uintptr_t align);
extern uintptr_t heap_available(struct Heap *h);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
static uint8_t pool[8192] __attribute__((aligned(64)));

int main(void) {
    uintptr_t base = (uintptr_t)pool;
    struct PhysRange r = { base, base + sizeof(pool) };
    struct Heap h = heap_new(r);
    CHECK(heap_available(&h) == sizeof(pool));

    // First alloc starts at the (already 64-aligned) base.
    uintptr_t a = heap_alloc(&h, 100, 16);
    CHECK(a == base);
    CHECK(a % 16 == 0);

    // Next alloc is aligned up past a's 100 bytes: align_up(base+100, 64) = base+128.
    uintptr_t b = heap_alloc(&h, 8, 64);
    CHECK(b % 64 == 0);
    CHECK(b == base + 128);
    CHECK(heap_available(&h) == sizeof(pool) - (128 + 8));

    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/heap.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: heap-test — kernel heap aligned bump allocation over a PhysRange computes correctly"
    exit 0
fi
echo "FAIL: heap-test — driver returned non-zero (failing CHECK line)"
exit 1
