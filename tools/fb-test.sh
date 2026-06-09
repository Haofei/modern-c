#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: fb-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/arch/fb_demo.mc" -o "$WORK/fb.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t fb_run(void);
int main(void){ return fb_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/fb.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: fb-test — linear framebuffer device: set/get independent 32-bit pixels by coordinate"; exit 0; fi
echo "FAIL: fb-test"; exit 1
