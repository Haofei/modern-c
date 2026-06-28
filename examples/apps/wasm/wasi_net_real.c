// examples/apps/wasm/wasi_net_real.c — Phase-6 real-TCP peer, the WASM mirror of
// examples/agents/agent_net_real_tool.js. The guest's brokered net_fetch reaches a LIVE HTTP server
// through the kernel's real TCP transport (net_fetch_tcp) over virtio-net — not the mock broker. The
// first allowed web fetch returns a positive byte count from the real response; endpoint 9 is denied;
// the second web fetch is budget-exhausted. Prints "net-real: ok" only on the fully-correct path,
// which (with the harness's HTTP access-log + pcap checks) proves a real datagram round-trip.
#include <stdio.h>

__attribute__((import_module("mc"), import_name("net_fetch")))
extern int net_fetch(int endpoint, int token);

int main(void) {
    int n = net_fetch(1, 7);                  // allowed: real HTTP GET -> positive byte count
    if (!(n > 0)) { printf("net-real: fail web-empty %d\n", n); return 1; }

    int v = net_fetch(9, 999);                // not in the egress allowlist -> denied
    if (v != -13) { printf("net-real: fail evil %d\n", v); return 1; }   // -E_DENIED

    v = net_fetch(1, 8);                       // budget exhausted -> back-pressured
    if (v != -11) { printf("net-real: fail budget %d\n", v); return 1; } // -E_AGAIN

    printf("net-real: ok\n");
    return 0;
}
