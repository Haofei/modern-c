#!/usr/bin/env bash
# Generic-collection test: a module imports the generic heap-backed `std/collections/hashmap`
# (`StrHashMap<V>`), uses it at a concrete value type (u32, monomorphized) with a malloc-backed
# allocator, and is linked/run. Proves insert-with-grow+rehash, linear-probe collisions,
# lookup (pointer + by-value fallback), overwrite, contains, absent-key misses, len, and free.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/hashmap_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: hashmap-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/hashmap.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }
extern uint32_t hashmap_sum(uint32_t n);
extern uint32_t hashmap_absent(void);
int main(void) {
    // sum_{i in 0..n} (2i+1) = n*n; key 0 overwritten 1 -> 99 adds 98 for n > 0.
    if (hashmap_sum(0)   != 0u)              return 1;  // empty map
    if (hashmap_sum(1)   != 1u*1u + 98u)     return 2;  // single key, then overwritten
    if (hashmap_sum(7)   != 7u*7u + 98u)     return 3;  // one grow (cap 8 -> 16)
    if (hashmap_sum(200) != 200u*200u + 98u) return 4;  // many grows + rehash + collisions
    if (hashmap_absent() != 116u)            return 5;  // contains/get present + absent misses
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/hashmap.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: hashmap-test — generic heap-backed std/collections/hashmap (StrHashMap<V>) monomorphized, grew, rehashed, probed, looked up, and freed"
    exit 0
fi
echo "FAIL: hashmap-test — program returned non-zero"
exit 1
