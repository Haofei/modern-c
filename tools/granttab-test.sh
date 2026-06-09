#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: grant-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/ipc/granttab_demo.mc" -o "$WORK/granttab.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t granttab_run(void);
int main(void){ return granttab_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/granttab.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: granttab-test — granttab (kernel/lib): owner-tracked grants, bounded IPC sharing, revoke-on-death"; exit 0; fi
echo "FAIL: grant-test"; exit 1
