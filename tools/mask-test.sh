#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mask-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/mem/mask_demo.mc" -o "$WORK/mask.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t mask_run(void);
int main(void){ return mask_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/mask.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: mask-test — Mask32: bounds-checked set/clear/contains, take_first (ascending, removing), out-of-range bit ignored"; exit 0; fi
echo "FAIL: mask-test"; exit 1
