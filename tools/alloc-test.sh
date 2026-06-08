#!/usr/bin/env bash
# Allocator test: allocate through the type-erased std/alloc Allocator (closures
# capturing a bump Heap) and confirm allocations advance + stay aligned.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: alloc-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/alloc_demo.mc" -o "$WORK/a.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t alloc_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(alloc_demo_run() == 1); // two aligned, advancing allocs via the Allocator
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/a.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: alloc-test — generic Allocator (std/alloc) over a captured bump heap: aligned, advancing allocation"; exit 0; fi
echo "FAIL: alloc-test"; exit 1
