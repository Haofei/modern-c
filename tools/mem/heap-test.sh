#!/usr/bin/env bash
# Kernel heap test: compile tests/mem/heap_host_driver.mc (which imports
# kernel/core/heap.mc) through the selected backend, link a minimal C harness
# that supplies a real pool and calls the MC entry point, and run it.
#
# All assertions live in MC (heap_host_test), so the harness mirrors NO MC struct
# layout — it only provides the trap/ksan stubs the heap references, the pool, and
# main(). This is why a layout drift (e.g. heap.mc growing a field) can no longer
# silently corrupt memory past a hand-written C mirror: there is no mirror.
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

DRIVER="$HERE/tests/mem/heap_host_driver.mc"
case "$BACKEND" in
    c)
        MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$DRIVER" -o "$WORK/heap.o" >/dev/null
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$DRIVER" -o "$WORK/heap.o" >/dev/null
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        exit 2
        ;;
esac

cat >"$WORK/driver.c" <<'EOF'
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

// Referenced only by heap.mc's never-taken ksan branch (default heap has ksan==0).
void mc_ksan_poison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }
void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }

// The MC entry. No Heap struct is mirrored here: heap_host_test builds and asserts
// the heap entirely in MC and returns 0 on success or a nonzero check id.
extern uint32_t heap_host_test(uintptr_t pool_start, uintptr_t pool_len);

static uint8_t pool[8192] __attribute__((aligned(4096)));

int main(void) {
    return (int)heap_host_test((uintptr_t)pool, sizeof(pool));
}
EOF

DRIVER_CFLAGS=(-std=c11 -Wall -Wextra -Werror)
"$CLANG" "${DRIVER_CFLAGS[@]}" "$WORK/driver.c" "$WORK/heap.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend kernel heap aligned bump allocation over a PhysRange computes correctly (MC-side asserts, no struct mirror)"
    exit 0
fi
echo "FAIL: $TEST_NAME — driver returned non-zero (failing check id or signal, rc=$rc)"
exit 1
