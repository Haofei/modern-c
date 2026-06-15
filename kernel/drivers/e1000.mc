// kernel/drivers/e1000 — probe for the Intel 82540EM (e1000) NIC, a *real* network chip
// (QEMU emulates the actual silicon, unlike paravirtual virtio). We discover it on the
// PCI bus by its vendor/device id and read its resource (BAR0) — the first steps of a
// real-hardware driver.

import "kernel/drivers/pci.mc";

const E1000_VENDOR: u16 = 0x8086; // Intel
const E1000_DEVICE: u16 = 0x100E; // 82540EM

// Returns 1 if the e1000 is present and its config is readable, else 0.
export fn e1000_probe() -> u32 {
    switch pci_find(E1000_VENDOR, E1000_DEVICE) {
        ok(dev) => {
            // confirm we can read its resource register (a real driver maps this BAR)
            switch pci_bar0(dev) {
                ok(bar) => {
                    return 1;
                }
                err(e) => {
                    return 0;
                }
            }
        }
        err(e) => {
            return 0; // not found
        }
    }
}
