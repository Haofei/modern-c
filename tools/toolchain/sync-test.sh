#!/usr/bin/env bash
# std/sync runtime test: a guarded critical section links against a single-core
# lock implementation and runs; the linear Guard balances acquire/release.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/sync_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: sync-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/sync.o" >/dev/null

cat >"$WORK/driver.c" <<'CEOF'
#include <stdint.h>
struct SpinLock { uint32_t state; };
static int balance = 0;
// Single-core lock: a plain flag suffices; the linear Guard provides the safety.
// The seam passes only pointers/scalars (extern struct-by-value is rejected); the
// linear Guard/IrqGuard witnesses live entirely on the MC side (std/sync/sync.mc).
void mc_spin_acquire(struct SpinLock *l) { l->state = 1; balance++; }
void mc_spin_release(struct SpinLock *l) { l->state = 0; balance--; }
uintptr_t mc_spin_acquire_irqsave(struct SpinLock *l) { l->state = 1; balance++; return 0; }
void mc_spin_release_irqrestore(struct SpinLock *l, uintptr_t flags) { (void)flags; l->state = 0; balance--; }
extern void guarded_add(struct SpinLock *l, uint32_t *counter, uint32_t delta);
int main(void) {
    struct SpinLock l = { 0 };
    uint32_t c = 0;
    for (int i = 0; i < 5; i++) guarded_add(&l, &c, 10);
    if (c != 50) return 1;        // critical sections ran
    if (balance != 0) return 2;   // every lock released exactly once
    if (l.state != 0) return 3;   // not left held
    return 0;
}
CEOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/sync.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: sync-test — std/sync guarded critical section linked and ran (lock balance preserved)"
    exit 0
fi
echo "FAIL: sync-test — program returned non-zero"
exit 1
