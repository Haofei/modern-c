#!/usr/bin/env bash
# Generic-collection test: a module imports the generic heap-backed `std/collections/dynarray`
# (`Vec<T>`), uses it at a concrete element type (monomorphized) with a malloc-backed
# allocator, and is linked/run. Proves push-with-grow, get/set, pop order, and free+reuse.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/vec_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: vec-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/vec.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }
extern uint32_t vec_sum_to(uint32_t n);
extern uint32_t vec_pop_sum(uint32_t n);
int main(void) {
    if (vec_sum_to(1000) != 499500u) return 1;   // sum 0..999
    if (vec_sum_to(0)    != 0u)      return 2;    // empty
    if (vec_sum_to(1)    != 0u)      return 3;    // just element 0
    if (vec_pop_sum(100) != 4950u + 7u) return 4; // sum 0..99 popped LIFO, + reused push(7)
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/vec.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: vec-test — generic heap-backed std/collections/dynarray (Vec<T>) monomorphized, grew, popped, freed, and ran"
    exit 0
fi
echo "FAIL: vec-test — program returned non-zero"
exit 1
