// Bare-metal riscv64 M-mode (`-bios none`) virtio-net RX/TX runtime — in PURE MC.
// The all-MC replacement for kernel/drivers/virtio/net_runtime.c. Drives the EXISTING
// typed MC net path (kernel/main.mc -> virtio_net + ethernet/arp) under the M-mode
// `-bios none` path: send a broadcast ARP request for the gateway (10.0.2.2) and
// receive slirp's reply on the RX queue.
//
// Modeled verbatim on tests/qemu/arch/blk_mmode_demo.mc: the device probe is the
// shared MC virtio-mmio probe (sbi_virtio_probe.mc — pure MMIO, identical in M-/S-mode);
// the two queues' vring memory + Virtq handles are zeroed globals (the driver lays out
// each split virtqueue over them); the console is the bare 16550 UART; and the std/dma +
// std/time platform primitives (CLINT mtime + bump DMA pool) are a SEPARATE MC object
// (mmode_dma_time.mc) linked beside this one so its definitions bind the std `extern fn`
// seam by name (a single MC unit may not both import the extern decl and define it).

import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/main.mc"; // kernel_main + the virtio-net driver / net stack

const VIRTIO_ID_NET: u32 = 1;
const UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;

// Separate vring memory for the RX (queue 0) and TX (queue 1) queues; the driver
// lays out each split virtqueue over these zeroed globals.
global g_rx_desc: DescTable;
global g_rx_avail: VringAvail;
global g_rx_used: VringUsed;
global g_tx_desc: DescTable;
global g_tx_avail: VringAvail;
global g_tx_used: VringUsed;
global g_rxq: Virtq;
global g_txq: Virtq;

fn uputc(c: u8) -> void {
    unsafe { raw.store<u8>(phys(UART_THR), c); }
}
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        uputc(b);
        i = i + 1;
    }
}
fn uputhex(v: u32) -> void {
    uputc(48); uputc(120); // "0x"
    var s: i32 = 28;
    while s >= 0 {
        let nib: u32 = (v >> (s as u32)) & 0xF;
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

    uputs("MC typed kernel booting\n");
    let rc: u32 = kernel_main(regs, &g_rxq, &g_txq);
    if rc != 0 {
        uputs("KERNEL-FAIL ");
        uputhex(rc);
        uputc(10);
        halt();
    }
    uputs("NET-PING-OK\n");
    halt();
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. `.text.start` pins `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
