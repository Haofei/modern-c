// kernel/platform/qemu_virt/resources — the QEMU `virt` board's device inventory: the fixed
// (id + MMIO + IRQ) resources the bus enumerates. This is the "platform describes resources"
// boot step, separated from any driver — a different board supplies its own inventory of the
// same shape, and the bus/driver/registry layers above are unchanged.

import "kernel/bus/device.mc";

const PLATFORM_NDEV: usize = 3;

export fn platform_ndev() -> usize {
    return PLATFORM_NDEV;
}

// Fill `d` with board device `idx` (id + resources, not yet attached). False if idx is out
// of range. virtio devices use the virtio vendor id (0x1AF4); the console is a 16550 UART.
export fn platform_device(idx: usize, d: *mut Device) -> bool {
    d.attached = false;
    d.class = .None;
    d.endpoint = 0;
    d.res.mmio_len = 0x1000;
    if idx == 0 {
        d.id.vendor = 0x1AF4; d.id.device = 1;        // virtio-net
        d.res.mmio_base = 0x10008000; d.res.irq = 8;
        return true;
    }
    if idx == 1 {
        d.id.vendor = 0x1AF4; d.id.device = 2;        // virtio-blk
        d.res.mmio_base = 0x10007000; d.res.irq = 7;
        return true;
    }
    if idx == 2 {
        d.id.vendor = 0x16550; d.id.device = 0;       // 16550 UART console
        d.res.mmio_base = 0x10000000; d.res.irq = 10;
        return true;
    }
    return false;
}
