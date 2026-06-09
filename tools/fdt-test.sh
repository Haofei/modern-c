#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: fdt-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/arch/fdt_demo.mc" -o "$WORK/fdt.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t fdt_run(void);
int main(void){ return fdt_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/fdt.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: fdt-test — device-tree (FDT) header parsing: magic validation + totalsize/version"; exit 0; fi
echo "FAIL: fdt-test"; exit 1
