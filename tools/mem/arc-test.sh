#!/usr/bin/env bash
# Arc<T> test: two owners share a value; dropping one doesn't free; dropping the last
# frees. (Leaking a handle is a compile error — see kernel/bad/arc_leak.mc.)
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: arc-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/mem/arc_demo.mc" -o "$WORK/arc.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t arc_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(arc_demo_run() == 1); // 2 owners, shared value, drop-one keeps, drop-last frees
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/arc.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: arc-test — Arc<T> shared ownership: clone adds an owner, last drop frees (handles leak-checked at compile time)"; exit 0; fi
echo "FAIL: arc-test"; exit 1
