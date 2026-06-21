// tests/x86/pci_x86_demo — x86-64 PCI device-discovery proof.
//
// Real PCI config-space enumeration on x86-64 via the legacy port-I/O CAM mechanism. The ONE
// arch-specific dependency is the config-space read primitive (x86 needs port I/O on 0xCF8/0xCFC),
// now expressed in PURE MC via outl/inl (kernel/arch/x86_64/port_io.mc) — MC reaches the x86 I/O
// ports through inline `out`/`in` exactly as it reaches MMIO through `raw`. EVERYTHING ELSE — the
// bus scan, the vendor match, the field decode — is arch-neutral MC here, mirroring the
// ENUMERATION shape of the RISC-V ECAM driver (kernel/drivers/pci.mc): pci_cfg_read32 / pci_find /
// pci_bar0.
//
// The runtime calls pci_x86_scan(out_vendor,out_device,out_class,out_bar0): we scan bus 0
// functions for the FIRST device whose vendor id is 0x1AF4 (virtio — the virtio-blk-pci QEMU
// attaches on the test command line), and report its identity through out-pointers (avoids a
// by-value struct return across the MC/C FFI, whose System-V ABI differs between MC's two
// backends — same convention as vm_x86_build). Returns 1 iff a real virtio device was found
// (NOT an all-ones absent-device read), else 0.

import "kernel/arch/x86_64/port_io.mc";

// Prefixed consts to avoid emit-c const-flatten collisions with other fixtures sharing a TU.
const PCI_X86_VENDOR_VIRTIO: u32 = 0x1AF4;
const PCI_X86_INVALID: u32 = 0xFFFF_FFFF; // the bus returns all-ones for an absent device/register

const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;

// The arch-specific config-space read primitive (legacy CAM port I/O), in PURE MC over outl/inl.
// CONFIG_ADDRESS (0xCF8): bit 31 = enable; bits 23..16 = bus; 15..11 = device; 10..8 = function;
// 7..2 = register (dword-aligned). CONFIG_DATA (0xCFC) then exposes the selected dword. This is
// the canonical x86 PCI configuration mechanism #1; it works on both `pc` (i440FX) and `q35`.
// (bus,dev,func) select the device; `off` is the 32-bit-aligned register offset within its
// 256-byte config space. Returns the 32-bit register value (all-ones if absent).
export fn pci_x86_cfg_read32(bus: u32, dev: u32, func: u32, off: u32) -> u32 {
    let addr: u32 = 0x8000_0000
                  | ((bus & 0xFF) << 16)
                  | ((dev & 0x1F) << 11)
                  | ((func & 0x07) << 8)
                  | (off & 0xFC);
    outl(PCI_CONFIG_ADDRESS, addr);
    return inl(PCI_CONFIG_DATA);
}

// 32-bit config read for bus 0, function 0 of device `dev`, register `off` — mirrors the riscv
// pci_cfg_read32 shape, but the underlying mechanism is x86 port I/O (the C extern), not MMIO.
fn pci_cfg_read32(dev: u32, off: u32) -> u32 {
    return pci_x86_cfg_read32(0, dev, 0, off);
}

// Scan bus 0 for the first virtio device (vendor 0x1AF4) and report its identity. Mirrors
// pci_find + pci_bar0 from the riscv driver. Writes vendor/device/class-code/bar0 through the
// out-pointers; returns 1 on a real find, 0 if no virtio device is present on the bus.
export fn pci_x86_scan(out_vendor: *mut u32, out_device: *mut u32, out_class: *mut u32, out_bar0: *mut u32) -> u32 {
    var dev: u32 = 0;
    while dev < 32 {
        let id: u32 = pci_cfg_read32(dev, 0); // register 0x00: device id (hi) | vendor id (lo)
        let vendor: u32 = id & 0xFFFF;
        if vendor == PCI_X86_VENDOR_VIRTIO {
            // register 0x08: class code (bits 24..31) | subclass (16..23) | prog-if | revision.
            let class_reg: u32 = pci_cfg_read32(dev, 0x08);
            // register 0x10: BAR0 (the device's first base address register).
            let bar0: u32 = pci_cfg_read32(dev, 0x10);
            *out_vendor = vendor;
            *out_device = (id >> 16) & 0xFFFF;
            *out_class = class_reg;
            *out_bar0 = bar0;
            return 1; // a real virtio device — vendor read back 0x1AF4, not all-ones
        }
        dev = dev + 1;
    }
    *out_vendor = PCI_X86_INVALID;
    *out_device = PCI_X86_INVALID;
    *out_class = PCI_X86_INVALID;
    *out_bar0 = PCI_X86_INVALID;
    return 0;
}
