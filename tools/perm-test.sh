#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: perm-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/proc/perm_demo.mc" -o "$WORK/perm.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t perm_run(void);
int main(void){ return perm_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/perm.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: perm-test — POSIX uid/gid + rwx-mode permission checks (owner/group/other, root bypass)"; exit 0; fi
echo "FAIL: perm-test"; exit 1
