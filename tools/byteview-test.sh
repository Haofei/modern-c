#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: byteview-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/byteview_demo.mc" -o "$WORK/byteview.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t byteview_run(void);
int main(void){ return byteview_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/byteview.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: byteview-test — ByteBuf<N>: bounds-checked get + set/copy_from/copy_to return typed OutOfBounds (no silent clamp) on a PAddr"; exit 0; fi
echo "FAIL: byteview-test"; exit 1
