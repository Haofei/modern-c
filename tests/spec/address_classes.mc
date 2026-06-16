// SPEC: section=16,17,D.1
// SPEC: milestone=address-class-deref
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PADDR_DEREF,E_VADDR_DEREF,E_USER_PTR_DEREF,E_MMIO_PTR_DEREF,E_DMA_ADDR_DEREF,E_PHYS_PTR_DEREF,E_DMA_ADDR_NOT_PADDR,E_DMA_ADDR_NOT_VADDR,E_ADDRESS_CLASS_MISMATCH,E_ADDRESS_CLASS_OPERATION,E_RETURN_TYPE_MISMATCH,E_INDEX_BASE_NOT_ARRAY_OR_SLICE

extern fn make_u8_pointer() -> *const u8;
extern fn takes_paddr(addr: PAddr) -> void;

extern mmio struct Uart16550 {
    data: Reg<u8, .read>,
}

extern struct Page {
    bytes: [4096]u8,
}

fn accept_direct_virtual_pointer_deref(p: *const u8) -> u8 {
    return p.*;
}

fn accept_direct_call_virtual_pointer_deref() -> u8 {
    return make_u8_pointer().*;
}

fn reject_direct_call_virtual_pointer_deref_return_type() -> *const u8 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return make_u8_pointer().*;
}

fn reject_paddr_deref(pa: PAddr) -> u8 {
    // EXPECT_ERROR: E_PADDR_DEREF
    return pa.*;
}

fn reject_vaddr_deref(va: VAddr) -> u8 {
    // EXPECT_ERROR: E_VADDR_DEREF
    return va.*;
}

fn reject_user_ptr_deref(buf: UserPtr<u8>) -> u8 {
    // EXPECT_ERROR: E_USER_PTR_DEREF
    return buf.*;
}

fn reject_const_user_ptr_deref(buf: UserPtr<const u8>) -> u8 {
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

fn reject_dma_addr_as_paddr(addr: DmaAddr) -> PAddr {
    // EXPECT_ERROR: E_DMA_ADDR_NOT_PADDR
    return addr;
}

fn reject_dma_addr_as_vaddr(addr: DmaAddr) -> VAddr {
    // EXPECT_ERROR: E_DMA_ADDR_NOT_VADDR
    return addr;
}

fn reject_paddr_as_vaddr(addr: PAddr) -> VAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_MISMATCH
    return addr;
}

fn reject_dma_addr_as_paddr_local(addr: DmaAddr) -> void {
    // EXPECT_ERROR: E_DMA_ADDR_NOT_PADDR
    let pa: PAddr = addr;
}

fn reject_dma_addr_as_paddr_assignment(addr: DmaAddr, fallback: PAddr) -> void {
    var pa: PAddr = fallback;
    // EXPECT_ERROR: E_DMA_ADDR_NOT_PADDR
    pa = addr;
}

fn reject_dma_addr_as_paddr_call_arg(addr: DmaAddr) -> void {
    // EXPECT_ERROR: E_DMA_ADDR_NOT_PADDR
    takes_paddr(addr);
}

fn reject_paddr_arithmetic(addr: PAddr, offset: usize) -> PAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_OPERATION
    return addr + offset;
}

fn reject_vaddr_ordering(left: VAddr, right: VAddr) -> bool {
    // EXPECT_ERROR: E_ADDRESS_CLASS_OPERATION
    return left < right;
}

fn reject_dma_addr_equality(left: DmaAddr, right: DmaAddr) -> bool {
    // EXPECT_ERROR: E_ADDRESS_CLASS_OPERATION
    return left == right;
}

fn reject_user_ptr_bitwise(ptr: UserPtr<u8>) -> UserPtr<u8> {
    // EXPECT_ERROR: E_ADDRESS_CLASS_OPERATION
    return ~ptr;
}

extern struct UserHeader {
    tag: u8,
}

fn reject_user_ptr_field(hdr: UserPtr<UserHeader>) -> u8 {
    // EXPECT_ERROR: E_USER_PTR_DEREF
    // A `.field` through a UserPtr is a kernel deref of user memory: forbidden.
    return hdr.tag;
}

fn reject_user_ptr_index(buf: UserPtr<u8>) -> u8 {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    // Indexing a UserPtr would reach through it: only copy_from_user may read it.
    return buf[0];
}
