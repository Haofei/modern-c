#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: waitqueue-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/waitqueue_demo.mc" -o "$WORK/wq.o" -Wno-switch-bool -Wno-unused-parameter >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t waitqueue_run(void);
int main(void){ return waitqueue_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra "$WORK/driver.c" "$WORK/wq.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: waitqueue-test — WaitQueue (kernel/lib): block current (park+yield), FIFO wake_one/wake_all, empty no-op, idle yield"; exit 0; fi
echo "FAIL: waitqueue-test"; exit 1
