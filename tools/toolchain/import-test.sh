#!/usr/bin/env bash
# Module-system test: compile a module that `import`s a sibling module and the
# standard library, then link and run it. Verifies `import "path";` resolves
# transitively through mcc-cc and that symbols from all files are present.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
APP="$HERE/tests/toolchain/app.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: import-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$APP" -o "$WORK/app.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t app_main(uint32_t);
// app_main(x) = clamp_u32(triple(x) + deep_fn(x), 0, 1000)
//             = clamp_u32(3x + (3x + 100), 0, 1000).
// x=5  -> clamp(15 + 115) = 130 ;  x=200 -> clamp(600 + 700) = 1000.
int main(void) {
    if (app_main(5) != 130) return 1;
    if (app_main(200) != 1000) return 2;
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/app.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: import-test — import-merged module (sibling + std) linked and ran"
    exit 0
fi
echo "FAIL: import-test — program returned non-zero"
exit 1
