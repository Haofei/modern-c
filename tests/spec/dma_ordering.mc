// SPEC: section=18,17,I.13,I.14
// SPEC: milestone=dma-ordering-composition
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,inspect
// SPEC: check=dma-ordering-composition

// Section 18 + section 17 composition: a DMA-descriptor handoff is a typed MMIO
// write whose value is a buf.dma_addr(), and cache.clean/invalidate are typed
// ordering barriers. Both participate in the section 17 MMIO acquire/release
// ordering set: a clean-for-device may not move after the .release descriptor
// write, and an invalidate-for-cpu precedes the CPU read of the buffer.

extern struct Packet {
    len: u16,
    tag: u8,
}

extern mmio struct DmaEngine {
    desc_addr: Reg<u64, .write>,
    control: Reg<u32, .read_write>,
}

fn program_noncoherent_dma(eng: MmioPtr<DmaEngine>, buf: DmaBuf<Packet, .noncoherent>) -> []mut Packet {
    // EXPECT: clean-before-handoff barrier composes with the .release descriptor write.
    cache.clean(buf);
    // EXPECT: descriptor handoff write of a dma_addr participates in section 17 ordering.
    eng.desc_addr.write(buf.dma_addr(), .release);
    // EXPECT: an acquire read fences later operations (status poll on the engine).
    let _status = eng.control.read(.acquire);
    // EXPECT: invalidate-before-read barrier precedes the CPU view of the buffer.
    cache.invalidate(buf);
    return buf.as_slice();
}
