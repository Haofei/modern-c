// IPC latency microbench (Phase 1.4 + 1.5): time N ipc_send + ipc_receive round-trips through
// a ProcTable and report cycles-per-round-trip via rdcycle. Each iteration exercises exactly the
// hot IPC funnel the two optimizations touch:
//   - ipc_send_try -> ipc_send_try_id_prov: ledger charge + mailbox_post (O(1) tail append) +
//     the provenance gate (branchless flag load; emit skipped when disabled — the production default).
//   - ipc_receive: mailbox_take (O(1) head pop) + ledger release.
// No context switch is involved: we flip `current` between two spawned slots so the round-trip
// measures the message machinery, not the scheduler. Sender A -> receiver B, drained every iter,
// so the bounded inbox never fills (no yield) and the ledger stays balanced (charge==release).

import "kernel/core/process.mc";
import "kernel/core/proc_ipc.mc";
import "kernel/core/ipc.mc";

global g_procs: ProcTable;

fn worker() -> void {}

// Read the RISC-V cycle counter. The kernel boots in M-mode (`-bios none`), so we read the
// machine `mcycle` CSR directly (the `rdcycle` pseudo-instruction needs the Zicntr extension,
// which -march=rv64imac does not enable; mcycle is always available in M-mode). On rv64 the
// single CSR read returns the full 64-bit counter.
fn read_cycle() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrr %0, 0xb00"
                out("r") v: u64
            }
        }
    }
    return v;
}

const TAG_BENCH: u32 = 0x7;

// Run `iters` send+receive round-trips; return total elapsed cycles (caller divides by iters).
export fn ipc_bench(iters: u32) -> u64 {
    proc_table_init(&g_procs);
    ipc_provenance_init(); // provenance stays OFF by default (production) — the branchless skip path
    let a: u32 = proc_spawn(&g_procs, 0x1000, worker); // pid 1
    let b: u32 = proc_spawn(&g_procs, 0x2000, worker); // pid 2

    let start: u64 = read_cycle();
    var i: u32 = 0;
    while i < iters {
        g_procs.current = a as usize;
        ipc_send_try(&g_procs, b, TAG_BENCH, i as u64, 0, 0); // charge + O(1) post + prov gate
        g_procs.current = b as usize;
        var msg: Message = message_zero();
        ipc_receive(&g_procs, &msg); // O(1) take + release
        i = i + 1;
    }
    let end: u64 = read_cycle();
    return end - start;
}
