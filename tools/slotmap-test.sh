#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: slotmap-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/mem/slotmap_demo.mc" -o "$WORK/slotmap.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t slotmap_run(void);
int main(void){ return slotmap_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/slotmap.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: slotmap-test — SlotMap<T,N>: stable index handles, alloc lowest-free, get/set/free bounds+liveness checked (BadHandle on use-after-free/double-free/oob), Full at capacity"; exit 0; fi
echo "FAIL: slotmap-test"; exit 1
