// kernel/arch/riscv64/sbi_virtio_probe — virtio-mmio device discovery for the
// S-mode/OpenSBI virtio runtimes, in PURE MC. Probes the 8 virtio-mmio slots on
// QEMU virt for a device with a given device_id (blk=2, net=1) and mints the typed
// `MmioPtr<VirtioMmio>` at the audited unsafe boundary. Imports only the virtio
// register type (std/virtio.mc) and addr (std/addr.mc), so it can be imported
// directly by the demo unit alongside the driver. (The DMA/time extern providers
// live in a separate compilation unit, sbi_dma_time.mc, to avoid the
// one-name-per-unit clash with the std extern declarations.)

import "std/addr.mc";
import "std/virtio.mc";

const VIRTIO_MMIO_BASE: usize = 0x10001000;
const VIRTIO_MMIO_STRIDE: usize = 0x1000;
const VIRTIO_MMIO_COUNT: usize = 8;
const VIRTIO_MMIO_MAGIC: u32 = 0x74726976;

// Probe for a device with the given device_id, returning its typed register
// pointer, or a null MmioPtr if absent. The raw MMIO loads + the MmioPtr mint are
// the audited unsafe boundary.
export fn find_virtio_device(device_id: u32) -> MmioPtr<VirtioMmio> {
    var i: usize = 0;
    while i < VIRTIO_MMIO_COUNT {
        let slot: usize = VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE;
        var magic: u32 = 0;
        var devid: u32 = 0;
        unsafe {
            magic = raw.load<u32>(pa(slot));      // MagicValue @ +0x00
            devid = raw.load<u32>(pa(slot + 8));  // DeviceID   @ +0x08
        }
        if magic == VIRTIO_MMIO_MAGIC && devid == device_id {
            unsafe { return slot as MmioPtr<VirtioMmio>; }
        }
        i = i + 1;
    }
    unsafe { return (0 as usize) as MmioPtr<VirtioMmio>; }
}

// True when the probe found a device (non-null register pointer).
export fn virtio_device_present(regs: MmioPtr<VirtioMmio>) -> bool {
    return (regs as usize) != 0;
}
