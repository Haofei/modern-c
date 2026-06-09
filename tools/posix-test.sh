#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: posix-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/posix_demo.mc" -o "$WORK/posix.o" -Wno-switch-bool -Wno-unused-parameter >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t posix_run(void);
int main(void){ return posix_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/posix.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: posix-test — POSIX syscall surface: getpid + open/write/read/close file lifecycle + ENOSYS, over the dispatch table"; exit 0; fi
echo "FAIL: posix-test"; exit 1
