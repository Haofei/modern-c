#!/usr/bin/env bash
# Arena test: bump-allocate from a move Arena, reset (batch reclaim + address reuse),
# and destroy (consume the linear resource).
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: arena-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/mem/arena_demo.mc" -o "$WORK/a.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t arena_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(arena_demo_run() == 1); // advancing+aligned allocs, reset reuses, destroy consumes
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/a.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: arena-test — move Arena: bump alloc, reset reclaims+reuses, destroy consumes the linear arena"; exit 0; fi
echo "FAIL: arena-test"; exit 1
