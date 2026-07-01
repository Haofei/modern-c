// Bare-metal riscv64 entry for the IPC latency microbench (tests/qemu/ipc/ipc_bench_demo.mc).
// Runs N send/receive round-trips, then prints "IPC-CYCLES <n>" where <n> is cycles per
// round-trip (total elapsed / iters). `_start` / `mc_halt` come from the shared M-mode
// bring-up runtime (context_runtime.c) linked beside this object.

import "tests/qemu/lib/test_report.mc";
import "std/fmt/fmt_sink.mc";

extern fn mc_halt() -> void;

// The bench (tests/qemu/ipc/ipc_bench_demo.mc): returns total cycles for `iters` round-trips.
extern fn ipc_bench(iters: u32) -> u64;

const ITERS: u32 = 100000;

export fn test_main() -> void {
    uputs("ipc-bench booting\n");
    let total: u64 = ipc_bench(ITERS);
    let per: u64 = total / (ITERS as u64);
    uputs("IPC-CYCLES ");
    fmt_put_dec(uputc, per);
    uputc(10); // '\n'
    uputs("ipc-bench done\n");
    mc_halt();
}
