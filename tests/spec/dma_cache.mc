// SPEC: section=18,I.13
// SPEC: milestone=dma-cache-core
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_DMA_CACHE_MODE,E_DMA_OPERATION,E_CALL_ARG_COUNT,dma-cache-core

extern struct Packet {
    len: u16,
    tag: u8,
}

fn accept_dma_addr(buf: DmaBuf<Packet, .noncoherent>) -> DmaAddr {
    return buf.dma_addr();
}

fn accept_noncoherent_cache_cycle(buf: DmaBuf<Packet, .noncoherent>) -> []mut Packet {
    cache.clean(buf);
    cache.invalidate(buf);
    return buf.as_slice();
}

fn accept_core_allows_unproven_slice(buf: DmaBuf<Packet, .noncoherent>) -> []mut Packet {
    return buf.as_slice();
}

fn accept_coherent_slice(buf: DmaBuf<Packet, .coherent>) -> []mut Packet {
    return buf.as_slice();
}

fn reject_coherent_cache_clean(buf: DmaBuf<Packet, .coherent>) -> void {
    // EXPECT_ERROR: E_DMA_CACHE_MODE
    cache.clean(buf);
}

fn reject_cache_non_dma(packet: Packet) -> void {
    // EXPECT_ERROR: E_DMA_OPERATION
    cache.invalidate(packet);
}

fn reject_dma_addr_argument(buf: DmaBuf<Packet, .noncoherent>) -> DmaAddr {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return buf.dma_addr(1);
}

fn reject_unknown_dma_operation(buf: DmaBuf<Packet, .noncoherent>) -> void {
    // EXPECT_ERROR: E_DMA_OPERATION
    buf.flush();
}
