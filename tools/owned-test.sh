#!/usr/bin/env bash
# Owned<T> test: create() a typed linear allocation, write/read it, own_free to consume.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: owned-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/mem/owned_demo.mc" -o "$WORK/o.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t owned_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(owned_demo_run() == 1); // create<T> -> write/read via address -> own_free
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/o.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: owned-test — create<T> typed linear allocation: write/read via address, own_free consumes (leak-checked)"; exit 0; fi
echo "FAIL: owned-test"; exit 1
