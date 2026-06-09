#!/usr/bin/env bash
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: service-test (no clang)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/service_demo.mc" -o "$WORK/svc.o" -Wno-switch-bool -Wno-unused-parameter >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
void mc_thread_init(void* a, unsigned long b, void* c) { (void)a; (void)b; (void)c; }
void mc_switch_context(void* a, void* b) { (void)a; (void)b; }
void mc_switch_context_vm(void* a, void* b, unsigned long c) { (void)a; (void)b; (void)c; }
extern uint32_t service_run(void);
int main(void){ return service_run()==1 ? 0 : 1; }
EOF
"$CLANG" -std=c11 -Wall -Wextra "$WORK/driver.c" "$WORK/svc.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: service-test — service (kernel/lib): request/reply over IPC, unknown-tag error reply, stateless loop with handler-held state"; exit 0; fi
echo "FAIL: service-test"; exit 1
