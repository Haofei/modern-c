// examples/apps/wasm/wasi_net_irq.c — Phase-6 S-mode virtio-net IRQ peer, the WASM mirror of
// examples/agents/agent_net_irq_tool.js. The guest calls the brokered net_fetch tool; the kernel
// services it through a REAL S-mode virtio-net PLIC interrupt and delivers the completion via
// SYS_POLL (the wasi_shim net_fetch wrapper submits then polls until the IRQ-driven completion
// arrives). The IRQ broker grants ONE web fetch (returns 1), denies endpoint 9, and back-pressures
// the second web fetch (budget). Prints "net-irq: ok" only on the fully-correct IRQ path.
#include <stdio.h>

__attribute__((import_module("mc"), import_name("net_fetch")))
extern int net_fetch(int endpoint, int token);

int main(void) {
    int v = net_fetch(1, 7);             // allowed web fetch, completed via virtio-net IRQ -> 1
    if (v != 1) { printf("net-irq: bad value %d\n", v); return 1; }

    v = net_fetch(9, 999);               // not in the egress allowlist -> denied
    if (v >= 0) { printf("net-irq: denied FAIL %d\n", v); return 1; }

    v = net_fetch(1, 8);                 // budget exhausted -> back-pressured
    if (v >= 0) { printf("net-irq: budget FAIL %d\n", v); return 1; }

    printf("net-irq: ok\n");
    return 0;
}
