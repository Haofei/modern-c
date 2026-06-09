#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: args-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/args_demo.mc" -o "$WORK/args.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t args_run(void);
int main(void){ return args_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/args.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: args-test — argv/envp: packed NUL-terminated argument vector with per-arg offsets"; exit 0; fi
echo "FAIL: args-test"; exit 1
