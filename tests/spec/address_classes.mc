// SPEC: section=16,17,D.1
// SPEC: milestone=address-class-deref
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PADDR_DEREF,E_USER_PTR_DEREF,E_MMIO_PTR_DEREF,E_DMA_ADDR_DEREF,E_PHYS_PTR_DEREF

fn accept_direct_virtual_pointer_deref(p: *const u8) -> u8 {
    return p.*;
}

fn reject_paddr_deref(pa: PAddr) -> u8 {
    // EXPECT_ERROR: E_PADDR_DEREF
    return pa.*;
}

fn reject_user_ptr_deref(buf: UserPtr<u8>) -> u8 {
    // EXPECT_ERROR: E_USER_PTR_DEREF
    return buf.*;
}

fn reject_mmio_ptr_deref(uart: MmioPtr<Uart16550>) -> Uart16550 {
    // EXPECT_ERROR: E_MMIO_PTR_DEREF
    return uart.*;
}

fn reject_dma_addr_deref(addr: DmaAddr) -> u8 {
    // EXPECT_ERROR: E_DMA_ADDR_DEREF
    return addr.*;
}

fn reject_phys_ptr_deref(ptr: PhysPtr<Page>) -> Page {
    // EXPECT_ERROR: E_PHYS_PTR_DEREF
    return ptr.*;
}
