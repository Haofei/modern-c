#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: bcache-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/bcache_demo.mc" -o "$WORK/b.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t bcache_run(void);
int main(void){ return bcache_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror -Wno-switch-bool "$WORK/driver.c" "$WORK/b.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: bcache-test — write-back block cache: write stays dirty in cache, visible to reads, reaches device only on flush; hit/miss tracked"; exit 0; fi
echo "FAIL: bcache-test"; exit 1
