#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: scheduler-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/proc/scheduler_demo.mc" -o "$WORK/s.o" -Wno-switch-bool -Wno-unused-parameter >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t scheduler_run(void);
int main(void){ return scheduler_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra "$WORK/driver.c" "$WORK/s.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: scheduler-test — scheduler service: kernel ticks/accounts quantum, notifies the sched endpoint on the expiry edge (from=expired task), service refreshes policy"; exit 0; fi
echo "FAIL: scheduler-test"; exit 1
