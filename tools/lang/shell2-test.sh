#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: shell2-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/lang/shell2_demo.mc" -o "$WORK/shell2.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t shell2_run(void);
int main(void){ return shell2_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/shell2.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: shell2-test — shell: tokenizes a full command line into argv, runs builtins (echo with captured output, true=0/false=1, unknown=127), tolerates extra whitespace"; exit 0; fi
echo "FAIL: shell2-test"; exit 1
