#!/usr/bin/env bash
# Shared network buffer: a packet Arc-shared between two consumers; each reads the same
# bytes through its own owner; the buffer is freed exactly when the last owner drops.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: arc-pkt-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/arc_pkt_demo.mc" -o "$WORK/p.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t arc_pkt_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(arc_pkt_run() == 1); // both consumers read the shared bytes; last drop freed it
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/p.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: arc-pkt-test — packet Arc-shared between two consumers, freed when the last owner drops (skb/mbuf pattern)"; exit 0; fi
echo "FAIL: arc-pkt-test"; exit 1
