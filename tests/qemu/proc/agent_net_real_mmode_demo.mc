// Bare-metal riscv64 M-mode (`-bios none`) AGENT-NET-REAL runtime — in PURE MC.
// The all-MC replacement for kernel/drivers/virtio/agent_net_real_runtime.c. A sandboxed
// agent makes a REAL brokered network call: it drives the EXISTING MC entry
// agent_net_real_main (tests/qemu/proc/agent_net_real_demo.mc), which spawns an
// attenuated agent that performs a live web fetch through the broker (Allowed + Denied +
// Budget + audit -> stage mask 0xF).
//
// Net seam = the same recipe as http_get (shared MMIO probe + two virtqueues over zeroed
// globals + the shared mmode_dma_time.mc 8 MiB DMA pool). The green-thread context-switch
// surface (mc_switch_context/_vm/mc_thread_init) + the `.text.start` _start that calls
// this test_main are provided by the shared context_runtime.c (C), linked alongside — so
// this demo defines NO _start and uses LOCAL console names (uputc/uputs) to avoid the
// putc_/puts_/_start/test_main collisions the old C runtime inlined everything to dodge.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "tests/qemu/proc/agent_net_real_demo.mc"; // agent_net_real_main / agent_net_real_resp_*

const VIRTIO_ID_NET: u32 = 1;
const HTTP_PORT: u16 = 8080;          // must match tools/proc/agent-net-real-test.sh
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

global g_rx_desc: DescTable;
global g_rx_avail: VringAvail;
global g_rx_used: VringUsed;
global g_tx_desc: DescTable;
global g_tx_avail: VringAvail;
global g_tx_used: VringUsed;
global g_rxq: Virtq;
global g_txq: Virtq;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}
fn uputhex(v: u64) -> void {
    uputc(48); uputc(120); // "0x"
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 { uputc((48 + nib) as u8); } else { uputc((87 + nib) as u8); }
        s = s - 4;
    }
}

// Print the captured real response body (the broker's first allowed fetch), CR/LF raw.
fn dump_response() -> void {
    let n: usize = agent_net_real_resp_len();
    uputs("\nRESP-LEN=");
    uputhex(n as u64);
    uputc(10);
    uputs("RESP-BEGIN\n");
    var i: usize = 0;
    while i < n {
        uputc(agent_net_real_resp_byte(i));
        i = i + 1;
    }
    uputs("\nRESP-END\n");
}

export fn test_main() -> void {
    uputs("\nagent-net-real boot (sandboxed agent making a REAL brokered network call)\n");
    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_NET);
    if !virtio_device_present(regs) {
        uputs("NODEV\n");
        halt();
    }

    g_rxq.desc = &g_rx_desc;
    g_rxq.avail = &g_rx_avail;
    g_rxq.used = &g_rx_used;
    g_txq.desc = &g_tx_desc;
    g_txq.avail = &g_tx_avail;
    g_txq.used = &g_tx_used;

    // The MC story prints the stage markers W/D/B/A as each broker stage passes.
    let stages: u32 = agent_net_real_main(regs, &g_rxq, &g_txq, HTTP_PORT);
    uputs("\nstages=");
    uputhex(stages as u64);
    uputc(10);

    dump_response();

    if stages == 0xF {
        uputs("AGENT-NET-REAL-OK\n"); // real web fetch + Denied + Budget + audit
    } else {
        uputs("AGENT-NET-REAL-INCOMPLETE\n");
    }
    halt();
}

// NB: no `_start` here — context_runtime.c (linked alongside) provides the naked
// `.text.start` entry that sets the stack and `call`s this test_main, and it also carries
// the mc_switch_context/_vm/mc_thread_init green-thread context-switch primitives.
