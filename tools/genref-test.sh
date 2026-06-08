#!/usr/bin/env bash
# Generational-handle test: a handle resolves while live; after arena_reset it fails
# to resolve (StaleHandle) — runtime use-after-reset detection.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: genref-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/genref_demo.mc" -o "$WORK/g.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t genref_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(genref_demo_run() == 1); // live resolve r/w ok; post-reset resolve -> StaleHandle
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/g.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: genref-test — generational handle resolves live, traps StaleHandle after reset (use-after-reset caught)"; exit 0; fi
echo "FAIL: genref-test"; exit 1
