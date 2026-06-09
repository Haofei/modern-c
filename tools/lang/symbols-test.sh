#!/usr/bin/env bash
# Symbol-table test: build a sorted table and symbolize addresses to (index,offset),
# checking exact-start, mid-function, last-symbol, below-first, and unsorted-reject.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: symbols-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/lang/symbols_demo.mc" -o "$WORK/sym.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern void     st_init(void);
extern uint32_t st_add(uint64_t addr, uint32_t id);
extern uint64_t st_index(uint64_t pc);
extern uint64_t st_offset(uint64_t pc);
extern uint64_t st_id(uint64_t pc);
#define NONE ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    st_init();
    CHECK(st_add(0x1000, 10) == 1);
    CHECK(st_add(0x1100, 11) == 1);
    CHECK(st_add(0x1250, 12) == 1);
    CHECK(st_add(0x1400, 13) == 1);
    CHECK(st_add(0x1300, 99) == 0); // out of order -> rejected

    // exact start of the first function
    CHECK(st_index(0x1000) == 0 && st_offset(0x1000) == 0 && st_id(0x1000) == 10);
    // inside the second function
    CHECK(st_index(0x1180) == 1 && st_offset(0x1180) == 0x80 && st_id(0x1180) == 11);
    // exact start of the third
    CHECK(st_index(0x1250) == 2 && st_offset(0x1250) == 0 && st_id(0x1250) == 12);
    // just before the fourth (still in the third)
    CHECK(st_index(0x13FF) == 2 && st_offset(0x13FF) == 0x1AF && st_id(0x13FF) == 12);
    // past the last symbol (open-ended last function)
    CHECK(st_index(0x1500) == 3 && st_offset(0x1500) == 0x100 && st_id(0x1500) == 13);
    // below the first symbol -> not found
    CHECK(st_index(0x0500) == NONE && st_id(0x0500) == NONE);
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/sym.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: symbols-test — symbol table symbolizes addresses to function+offset (binary search), rejects unsorted/below-first"; exit 0; fi
echo "FAIL: symbols-test — driver returned non-zero (failing CHECK line)"; exit 1
