#!/usr/bin/env bash
# Const-generic test: one Ring<T,N> used at capacities 2 and 8 (full/overflow/FIFO).
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: constgen-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/constgen_demo.mc" -o "$WORK/c.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t constgen_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) { CHECK(constgen_run() == 1); return 0; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/c.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: constgen-test — const-generic Ring<T,N> at two capacities (2 and 8): [N]T + % N specialize per instance"; exit 0; fi
echo "FAIL: constgen-test"; exit 1
