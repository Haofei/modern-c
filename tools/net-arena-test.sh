#!/usr/bin/env bash
# Net-RX-on-arena test: per-packet scratch is an arena GenRef; the frame is built +
# demuxed on arena memory, reset per packet; a handle across a reset is caught stale.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: net-arena-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/net/net_arena_demo.mc" -o "$WORK/n.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t net_arena_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(net_arena_run() == 0x102); // 2 packets demuxed on arena scratch + stale handle caught
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/n.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: net-arena-test — RX scratch from a move Arena (GenRef), per-packet reset, use-after-reset caught"; exit 0; fi
echo "FAIL: net-arena-test"; exit 1
