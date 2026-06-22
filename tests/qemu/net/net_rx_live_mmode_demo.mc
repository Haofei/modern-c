// Bare-metal riscv64 M-mode (`-bios none`) live-RX runtime — in PURE MC.
// The all-MC replacement for kernel/drivers/virtio/net_rx_live_runtime.c. ARPs the
// gateway, copies the real reply frame off the RX queue, and pushes it through the
// production demux (rx_route) — driving the EXISTING MC path in net_rx_live_demo.mc.
//
// Same boot-seam shape as net_mmode_demo.mc: shared MMIO probe, two split virtqueues
// over zeroed globals, bare-16550 console, std/dma+std/time from mmode_dma_time.mc.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "tests/qemu/net/net_rx_live_demo.mc"; // rx_live_get_frame / rx_route_init / rx_route

const VIRTIO_ID_NET: u32 = 1;
const RX_ROUTE_PORT: u16 = 12345;
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
global g_framebuf: [2048]u8;

fn uputhex(v: u64) -> void {
    uputc(48); uputc(120); // "0x"
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 { uputc((48 + nib) as u8); } else { uputc((87 + nib) as u8); }
        s = s - 4;
    }
}
fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

export fn test_main() -> void {
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

    uputs("net-rx-live booting\n");
    rx_route_init(RX_ROUTE_PORT);
    let buf: usize = (&g_framebuf[0]) as usize;
    // ARP the gateway; copy the real reply frame off the RX queue.
    let n: usize = rx_live_get_frame(regs, &g_rxq, &g_txq, buf, 2048);
    if n == 0 {
        uputs("RX-NONE\n");
        halt();
    }
    let r: u32 = rx_route(buf, n);   // through the production demux
    uputs("RX-FRAME len=");
    uputhex(n as u64);
    if (r & 0x8000_0000) != 0 { uputs(" UDP-DELIVERED"); } else { uputs(" routed"); }
    uputc(10);
    uputs("NET-RX-LIVE-OK\n");
    halt();
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
