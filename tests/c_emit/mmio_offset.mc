// `@offset(N)` places MMIO registers at exact byte offsets (reserved padding is
// generated to reach each one), so a register map mirrors the datasheet without
// counting slots.
extern mmio struct Device {
    id: Reg<u32, .read> @offset(0x000),
    ctrl: Reg<u32, .read_write> @offset(0x010),
    status: Reg<u32, .read> @offset(0x070),
    doorbell: Reg<u32, .write> @offset(0x080),
}

fn read_status(dev: MmioPtr<Device>) -> u32 {
    return dev.status.read(.acquire);
}

fn ring(dev: MmioPtr<Device>) -> void {
    dev.doorbell.write(1, .release);
}
