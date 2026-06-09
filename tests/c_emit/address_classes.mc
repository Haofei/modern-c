extern fn takes_paddr(addr: PAddr) -> void;

fn pass_paddr(addr: PAddr) -> void {
    takes_paddr(addr);
}

fn keep_paddr(addr: PAddr) -> PAddr {
    return addr;
}

fn keep_vaddr(addr: VAddr) -> VAddr {
    return addr;
}

fn keep_dma_addr(addr: DmaAddr) -> DmaAddr {
    return addr;
}

fn keep_user_ptr(ptr: UserPtr<u8>) -> UserPtr<u8> {
    return ptr;
}

fn keep_const_user_ptr(ptr: UserPtr<const u8>) -> UserPtr<const u8> {
    return ptr;
}

fn keep_phys_ptr(ptr: PhysPtr<u8>) -> PhysPtr<u8> {
    return ptr;
}
