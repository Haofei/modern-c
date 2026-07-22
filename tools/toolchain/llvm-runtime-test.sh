#!/usr/bin/env bash
# LLVM runtime/toolchain coverage: compile imported generic std/stack,
# std/sync guarded critical sections, and fn-pointer indirect calls through
# mcc-llvm-cc, link them into one C driver, and run the checks.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: llvm-runtime-test (clang not found)"; exit 0; }
command -v llc >/dev/null 2>&1 || { echo "SKIP: llvm-runtime-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/toolchain/stack_user.mc" -o "$WORK/stack.o" >/dev/null
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/toolchain/sync_user.mc" -o "$WORK/sync.o" >/dev/null
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/c_emit/fn_pointer.mc" -o "$WORK/fnptr.o" >/dev/null

cat >"$WORK/driver.c" <<'CEOF'
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

struct SpinLock { uint32_t state; };
static int balance = 0;

// The seam passes only pointers/scalars (extern struct-by-value is rejected); the
// linear Guard/IrqGuard witnesses live entirely on the MC side (std/sync/sync.mc).
void mc_spin_acquire(struct SpinLock *l) {
    l->state = 1;
    balance++;
}

void mc_spin_release(struct SpinLock *l) {
    l->state = 0;
    balance--;
}

uintptr_t mc_spin_acquire_irqsave(struct SpinLock *l) {
    l->state = 1;
    balance++;
    return 0;
}

void mc_spin_release_irqrestore(struct SpinLock *l, uintptr_t flags) {
    (void)flags;
    l->state = 0;
    balance--;
}

extern uint32_t stack_top_two_sum(uint32_t a, uint32_t b, uint32_t c);
extern void guarded_add(struct SpinLock *l, uint32_t *counter, uint32_t delta);
extern uint32_t run(void);

int main(void) {
    if (stack_top_two_sum(1, 2, 3) != 8) return 1;
    if (stack_top_two_sum(10, 20, 30) != 53) return 2;

    struct SpinLock l = { 0 };
    uint32_t c = 0;
    for (int i = 0; i < 5; i++) guarded_add(&l, &c, 10);
    if (c != 50) return 3;
    if (balance != 0) return 4;
    if (l.state != 0) return 5;

    if (run() != 19) return 6;
    return 0;
}
CEOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/stack.o" "$WORK/sync.o" "$WORK/fnptr.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: llvm-runtime-test — imported generic stack, std/sync guard, and fn pointers lowered through LLVM, linked, and ran"
    exit 0
fi
echo "FAIL: llvm-runtime-test — program returned non-zero"
exit 1
