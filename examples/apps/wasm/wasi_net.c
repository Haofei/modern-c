// examples/apps/wasm/wasi_net.c — the Phase-3 guest: a WASM agent driving the brokered, FETCH-ONLY
// network egress tool, the WASM mirror of examples/agents/agent_net_tool.js. It imports the
// MC host tool `net_fetch(endpoint, token)` (module "mc") — NOT general WASI sockets — which the
// shim maps onto TOOL_OP_NET_FETCH through the kernel net broker (egress allowlist -> budget ->
// endpoint). The kernel grants endpoint 1 (web), denies endpoint 9 (evil), with a budget of 2:
//   - fetch(1,7) -> 107            (allowed; web handler returns token+100)
//   - fetch(9,999) -> -13 EDENIED  (not in the egress allowlist)
//   - fetch(1,8) -> 108            (allowed; second and last budget unit)
//   - fetch(1,9) -> -11 EAGAIN     (budget exhausted)
// Prints "net: ok" ONLY on the fully-correct path. net_fetch returns the broker's scalar result
// (>=0) or a negative kernel errno directly (the guest is MC-aware, exactly as a JS agent calling
// host_net_fetch is). See docs/wasm-migration-plan.md Phase 3.

#include <stdio.h>

__attribute__((import_module("mc"), import_name("net_fetch")))
extern int net_fetch(int endpoint, int token);

int main(void) {
    int v = net_fetch(1, 7);
    if (v != 107) { printf("net: fail web=%d\n", v); return 1; }

    v = net_fetch(9, 999);
    if (v != -13) { printf("net: fail evil=%d\n", v); return 1; }   // -E_DENIED
    printf("net: evil denied\n");

    v = net_fetch(1, 8);
    if (v != 108) { printf("net: fail web2=%d\n", v); return 1; }

    v = net_fetch(1, 9);
    if (v != -11) { printf("net: fail budget=%d\n", v); return 1; } // -E_AGAIN
    printf("net: budget exhausted\n");

    printf("net: ok\n");
    return 0;
}
