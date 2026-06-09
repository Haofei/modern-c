#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: tryelse-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/tryelse_demo.mc" -o "$WORK/tryelse.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t tryelse_run(void);
int main(void){ return tryelse_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/tryelse.o" -o "$WORK/app"
if "$WORK/app"; then echo 'PASS: tryelse-test — postfix-? with else remaps a subsystem error into the layer error type (ok + mapped-err paths)'; exit 0; fi
echo "FAIL: tryelse-test"; exit 1
