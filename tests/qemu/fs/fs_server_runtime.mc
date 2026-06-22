// Bare-metal riscv64 M-mode test entry for the FS-server demo
// (tests/qemu/fs/fs_server_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/fs_server_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start` calls
// the `test_main` exported here. This unit supplies the physical region the kernel
// heap sub-allocates per-thread stacks from, runs the SAME existing MC demo (a client
// opens, writes "OK", re-opens, reads back, and verifies — all over IPC to the FS
// server), and reports FS-SERVER-OK on success — writing the bare 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The FS-server demo (tests/qemu/fs/fs_server_demo.mc): a client open/write/read
// round-trips a file across the IPC boundary to the VFS server. Returns 1 on success.
extern fn fs_server_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("fs-server booting\n");
    let r: u32 = fs_server_demo((&g_heap_region) as usize, 262144);
    if r == 1 {
        uputs("FS-SERVER-OK\n");
    } else {
        uputs("FS-SERVER-FAIL\n");
    }
    mc_halt();
}
