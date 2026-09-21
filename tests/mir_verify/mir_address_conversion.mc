extern fn takes_paddr(addr: PAddr) -> void;

fn reject_dma_addr_return(addr: DmaAddr) -> PAddr {
    return addr;
}

fn reject_dma_addr_as_vaddr(addr: DmaAddr) -> VAddr {
    return addr;
}

fn reject_paddr_as_vaddr(addr: PAddr) -> VAddr {
    return addr;
}

fn reject_dma_addr_local(addr: DmaAddr) -> void {
    let pa: PAddr = addr;
}

fn reject_dma_addr_assignment(addr: DmaAddr, fallback: PAddr) -> void {
    var pa: PAddr = fallback;
    pa = addr;
}

fn reject_dma_addr_call_arg(addr: DmaAddr) -> void {
    takes_paddr(addr);
}
