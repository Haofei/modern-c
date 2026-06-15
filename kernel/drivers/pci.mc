// kernel/drivers/pci — PCI Express config access + device scan via the ECAM window
// (memory-mapped config space at 0x30000000 on the QEMU 'virt' board). Reads a device's
// config registers and finds a device by vendor/device id — real device discovery.

import "std/addr.mc";

const PCIE_ECAM: usize = 0x3000_0000;
const PCI_INVALID: u32 = 0xFFFF_FFFF; // bus returns all-ones for an absent device/register

// Typed errors — NO sentinels: a caller can't mistake an all-ones bus read for a real id.
enum PciError {
    NotFound,   // no device on bus 0 matches vendor:device
    NoResource, // BAR register read back as all-ones (absent/unreadable)
}

// 32-bit config read for bus 0, device `dev`, function 0, register `off`.
export fn pci_cfg_read32(dev: u32, off: u32) -> u32 {
    let addr: usize = PCIE_ECAM + ((dev as usize) << 15) + (off as usize);
    var v: u32 = 0;
    unsafe {
        v = raw.load<u32>(phys(addr));
    }
    return v;
}

// Scan bus 0 for the first device matching vendor:device; NotFound if absent.
export fn pci_find(vendor: u16, device: u16) -> Result<u32, PciError> {
    var d: u32 = 0;
    while d < 32 {
        let id: u32 = pci_cfg_read32(d, 0);
        let v: u16 = (id & 0xFFFF) as u16;
        let dv: u16 = ((id >> 16) & 0xFFFF) as u16;
        if v == vendor {
            if dv == device {
                return ok(d);
            }
        }
        d = d + 1;
    }
    return err(.NotFound);
}

// BAR0 of device `dev` (its MMIO/IO resource base register); NoResource if all-ones.
export fn pci_bar0(dev: u32) -> Result<u32, PciError> {
    let bar: u32 = pci_cfg_read32(dev, 0x10);
    if bar == PCI_INVALID {
        return err(.NoResource);
    }
    return ok(bar);
}
