#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mailbox-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/mailbox_demo.mc" -o "$WORK/mailbox.o" -Wno-switch-bool >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t mailbox_run(void);
int main(void){ return mailbox_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/mailbox.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: mailbox-test — Mailbox<T,N>: post/take, source-filtered take_from, drop-when-full"; exit 0; fi
echo "FAIL: mailbox-test"; exit 1
