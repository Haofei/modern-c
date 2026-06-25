// S-mode/OpenSBI virtio-net smoke — in PURE MC (no C). Revalidates the EXISTING MC
// virtio-net RX/TX driver + net stack (kernel/main.mc's kernel_main ->
// kernel/drivers/virtio/virtio_net.mc) under REAL OpenSBI firmware in S-mode,
// instead of the M-mode `-bios none` path. This is the all-MC replacement for
// kernel/arch/riscv64/net_smode_runtime.c.
//
// The boot seam (a0=hartid/a1=dtb preserved into s_entry), the SBI console +
// shutdown, the rdtime-backed time source (the CLINT mtime MMIO faults under
// OpenSBI's PMP), the bump DMA pool, and the virtio-mmio device probe are the
// shared MC modules (sbi.mc / sbi_virtio_platform.mc). The separate RX (queue 0) +
// TX (queue 1) vring memory and the two Virtq handles are provided here as zeroed
// globals (the driver does vq_setup over them); the driver call (kernel_main) is
// IDENTICAL to the M-mode path. The guest sends a broadcast ARP request for the
// gateway + an ICMP echo and must receive slirp's replies on the RX queue. satp is
// left 0 (Bare = flat physical); OpenSBI's PMP permits S-mode virtio-mmio + RAM DMA.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/main.mc";

const VIRTIO_ID_NET: u32 = 1;

// Separate vring memory for the RX (queue 0) and TX (queue 1) queues (zeroed in
// BSS; the driver lays out each split virtqueue over its three regions).
global g_rx_desc: DescTable;
global g_rx_avail: VringAvail;
global g_rx_used: VringUsed;
global g_tx_desc: DescTable;
global g_tx_avail: VringAvail;
global g_tx_used: VringUsed;
global g_rxq: Virtq;
global g_txq: Virtq;

export fn s_entry(_hartid: u64, _dtb: u64) -> void {
    sbi_puts("net: S-mode under OpenSBI\n");

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_NET);
    if !virtio_device_present(regs) {
        sbi_puts("NODEV\n");
        sbi_shutdown();
        while true {}
    }
    sbi_puts("net: device found\n");

    g_rxq.desc = &g_rx_desc;
    g_rxq.avail = &g_rx_avail;
    g_rxq.used = &g_rx_used;
    g_txq.desc = &g_tx_desc;
    g_txq.avail = &g_tx_avail;
    g_txq.used = &g_tx_used;

    sbi_puts("MC typed kernel booting\n");
    let rc: u32 = kernel_main(regs, &g_rxq, &g_txq);
    if rc != 0 {
        sbi_puts("KERNEL-FAIL ");
        put_hex(rc as u64);
        sbi_putchar(10); // '\n'
        sbi_shutdown();
        while true {}
    }
    sbi_puts("NET-PING-OK\n");

    sbi_shutdown();
    while true {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack but
// DO NOT clobber a0/a1 before the call, so s_entry receives them as its first two
// args. `#[section(".text.boot")]` pins `_start` to 0x80200000 (sbi.ld KEEPs
// .text.boot first), where OpenSBI jumps.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
