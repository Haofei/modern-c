extern struct Packet {
    len: u16,
    tag: u8,
}

extern mmio struct DmaEngine {
    desc_addr: Reg<u64, .write>,
    control: Reg<u32, .read_write>,
}

extern fn disable_interrupts() -> IrqOff;
extern fn restore_interrupts(cs: IrqOff) -> void;

fn program_noncoherent_dma(eng: MmioPtr<DmaEngine>, buf: DmaBuf<Packet, .noncoherent>) -> []mut Packet {
    cache.clean(buf);
    eng.desc_addr.write(buf.dma_addr(), .release);
    let status: u32 = eng.control.read(.acquire);
    cache.invalidate(buf);
    return buf.as_slice();
}

fn read_device(reg: u32, cs: IrqOff) -> u32 {
    return reg;
}

fn critical_read(reg: u32) -> u32 {
    let cs: IrqOff = disable_interrupts();
    let value: u32 = read_device(reg, cs);
    restore_interrupts(cs);
    return value;
}
