#!/usr/bin/env bash
# Generational-pool test: use-after-free, double-free, and stale-after-reuse all
# fail closed (StaleHandle); live handles work.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: pool-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/pool_demo.mc" -o "$WORK/p.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t pool_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(pool_demo_run() == 1); // live ok; UAF, double-free, stale-after-reuse all caught
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/p.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: pool-test — generational pool: use-after-free, double-free, stale-after-reuse all caught (StaleHandle)"; exit 0; fi
echo "FAIL: pool-test"; exit 1
