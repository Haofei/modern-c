#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: plugin-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/arch/plugin_demo.mc" -o "$WORK/plugin.o" -Wno-switch-bool -Wno-unused-parameter >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t plugin_run(void);
int main(void){ return plugin_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra "$WORK/driver.c" "$WORK/plugin.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: plugin-test — pluggable boot flow: platform devices -> bus probe/attach (closure providers) -> registry of device-class endpoints -> service discovery by class; NoDriver/Unavailable typed"; exit 0; fi
echo "FAIL: plugin-test"; exit 1
