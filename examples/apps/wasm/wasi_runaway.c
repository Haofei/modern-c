// examples/apps/wasm/wasi_runaway.c — Phase-5 CPU-runaway watchdog probe. A confined WASM guest that
// deliberately never yields: it prints a marker, then spins in an infinite compute loop making NO
// syscalls (so it never reaches SYS_EXIT). With the watchdog armed (a small mc_watchdog_ticks budget
// linked into the kernel), the machine-timer interrupt preempts the agent and, past the budget,
// kills it ("WATCHDOG-KILL"). This proves an untrusted agent cannot wedge the system with unbounded
// CPU — the runaway is detected and the system fails closed, rather than hanging to the QEMU timeout.
#include <stdio.h>

int main(void) {
    printf("runaway: entering infinite loop\n");
    fflush(stdout);
    volatile unsigned long x = 0;
    for (;;) { x = x + 1; }   // never exits, never syscalls — only the watchdog can stop this
    return 0;                 // unreachable
}
