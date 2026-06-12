#!/usr/bin/env bash
# Kernel heap test: compile kernel/core/heap.mc through the selected backend,
# link a C driver that exercises aligned bump allocation over a real pool, and
# run it.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-heap-test" || echo "heap-test")
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (llc not found)"; exit 0; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$BACKEND" in
    c)
        MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/kernel/core/heap.mc" -o "$WORK/heap.o" >/dev/null
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/kernel/core/heap.mc" -o "$WORK/heap.o" >/dev/null
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        exit 2
        ;;
esac

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

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
extern struct Heap heap_new(struct PhysRange r);
extern uintptr_t heap_alloc(struct Heap *h, uintptr_t size, uintptr_t align);
extern uintptr_t heap_available(struct Heap *h);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
static uint8_t pool[8192] __attribute__((aligned(64)));

int main(void) {
    uintptr_t base = (uintptr_t)pool;
    struct PhysRange r = { base, base + sizeof(pool) };
#ifdef MC_LLVM_BACKEND
    // TODO: cover heap_new once LLVM aggregate-return ABI matches the C ABI.
    struct Heap h = { r, base };
#else
    struct Heap h = heap_new(r);
#endif
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

DRIVER_CFLAGS=(-std=c11 -Wall -Wextra -Werror)
if [ "$BACKEND" = llvm ]; then
    DRIVER_CFLAGS+=(-DMC_LLVM_BACKEND=1)
fi
"$CLANG" "${DRIVER_CFLAGS[@]}" "$WORK/driver.c" "$WORK/heap.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend kernel heap aligned bump allocation over a PhysRange computes correctly"
    exit 0
fi
echo "FAIL: $TEST_NAME — driver returned non-zero (failing CHECK line or signal, rc=$rc)"
exit 1
