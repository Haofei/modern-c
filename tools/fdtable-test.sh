#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: fdtable-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/fdtable_demo.mc" -o "$WORK/fdtable.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t fdtable_run(void);
int main(void){ return fdtable_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/fdtable.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: fdtable-test — fd table: alloc pipe/socket fds, select finds the ready one, close frees it"; exit 0; fi
echo "FAIL: fdtable-test"; exit 1
