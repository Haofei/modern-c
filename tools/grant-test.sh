#!/usr/bin/env bash
# Memory-grant test: bounded delegation (in-bounds ok, OOB rejected) + revocation.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: grant-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/ipc/grant_demo.mc" -o "$WORK/g.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t grant_demo_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) { CHECK(grant_demo_run() == 1); return 0; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/g.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: grant-test — memory grant: bounded delegation (OOB rejected) + revocation (stale ref caught)"; exit 0; fi
echo "FAIL: grant-test"; exit 1
