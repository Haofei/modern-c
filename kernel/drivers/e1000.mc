// kernel/drivers/e1000 — probe for the Intel 82540EM (e1000) NIC, a *real* network chip
// (QEMU emulates the actual silicon, unlike paravirtual virtio). We discover it on the
// PCI bus by its vendor/device id and read its resource (BAR0) — the first steps of a
// real-hardware driver.

import "kernel/drivers/pci.mc";

const E1000_VENDOR: u16 = 0x8086; // Intel
const E1000_DEVICE: u16 = 0x100E; // 82540EM

// Returns 1 if the e1000 is present and its config is readable, else 0.
export fn e1000_probe() -> u32 {
    let dev: u32 = pci_find(E1000_VENDOR, E1000_DEVICE);
    if dev == 0xFFFF_FFFF {
        return 0; // not found
    }
    // confirm we can read its resource register (a real driver maps this BAR)
    let bar: u32 = pci_bar0(dev);
    if bar == 0xFFFF_FFFF {
        return 0;
    }
    return 1;
}
