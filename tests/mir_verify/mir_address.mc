extern fn make_paddr() -> PAddr;

fn reject_paddr_deref(pa: PAddr) -> u8 {
    return pa.*;
}

fn reject_vaddr_deref(va: VAddr) -> u8 {
    return va.*;
}

fn reject_user_ptr_deref(buf: UserPtr<u8>) -> u8 {
    return buf.*;
}

fn reject_mmio_ptr_deref(uart: MmioPtr<Uart>) -> Uart {
    return uart.*;
}

fn reject_dma_addr_deref(addr: DmaAddr) -> u8 {
    return addr.*;
}

fn reject_phys_ptr_deref(ptr: PhysPtr<Page>) -> Page {
    return ptr.*;
}

fn reject_call_deref() -> u8 {
    return make_paddr().*;
}

fn reject_paddr_arithmetic(addr: PAddr, offset: usize) -> PAddr {
    return addr + offset;
}
