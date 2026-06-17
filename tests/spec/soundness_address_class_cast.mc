// SPEC: section=15,16,17,D.4
// SPEC: milestone=soundness-address-class-cast
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ADDRESS_CLASS_CAST,E_ADDRESS_CLASS_MISMATCH,E_DMA_ADDR_NOT_PADDR,E_DMA_ADDR_NOT_VADDR

// SOUNDNESS SOURCE OF TRUTH — address-class laundering via `as` / `bitcast`.
//
// The built-in address classes (PAddr/VAddr/DmaAddr/UserPtr/MmioPtr/PhysPtr) are
// kept distinct so the checker can stop a physical address being dereferenced as
// virtual, a device pointer being forged from an integer, etc. The implicit
// conversion sites were already gated; this fixture pins the EXPLICIT `as` and
// `bitcast` paths (the laundering hole). A re-open — wiring `as`/bitcast around the
// gate — turns this file red. The controlled escape is `unsafe`; the EXTRACT
// direction (address class -> usize) and same-class identity casts stay accepted
// (they cannot deref or forge), so the typed pa()/va()/dma()/mmio constructors and
// the uaccess/DMA boundaries still compile.

extern mmio struct Dev {
    data: Reg<u32, .read_write>,
}

extern struct Page {
    bytes: [4096]u8,
}

// ---- CROSS-CLASS: casting between two DIFFERENT address classes (forge) ----

fn reject_paddr_as_vaddr(p: PAddr) -> VAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_MISMATCH
    return p as VAddr;
}

fn reject_vaddr_as_paddr(v: VAddr) -> PAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_MISMATCH
    return v as PAddr;
}

fn reject_dma_as_paddr(d: DmaAddr) -> PAddr {
    // EXPECT_ERROR: E_DMA_ADDR_NOT_PADDR
    return d as PAddr;
}

fn reject_dma_as_vaddr(d: DmaAddr) -> VAddr {
    // EXPECT_ERROR: E_DMA_ADDR_NOT_VADDR
    return d as VAddr;
}

fn reject_paddr_as_mmio(p: PAddr) -> MmioPtr<Dev> {
    // EXPECT_ERROR: E_ADDRESS_CLASS_MISMATCH
    return p as MmioPtr<Dev>;
}

// ---- MINT: forging an address class from a non-address source ----

fn reject_int_as_mmio(n: usize) -> MmioPtr<Dev> {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return n as MmioPtr<Dev>;
}

fn reject_int_as_paddr(n: usize) -> PAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return n as PAddr;
}

fn reject_int_as_vaddr(n: usize) -> VAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return n as VAddr;
}

fn reject_int_as_userptr(n: usize) -> UserPtr<u8> {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return n as UserPtr<u8>;
}

fn reject_roundtrip_int_as_vaddr(p: PAddr) -> VAddr {
    // The `(p as usize)` extract is fine, but re-minting VAddr from the integer is the forge.
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return (p as usize) as VAddr;
}

// ---- BITCAST: minting / crossing an address class via layout reinterpret ----

fn reject_bitcast_ptr_to_mmio(p: *u8) -> MmioPtr<Dev> {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return bitcast<MmioPtr<Dev>>(p);
}

fn reject_bitcast_int_to_paddr(n: usize) -> PAddr {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return bitcast<PAddr>(n);
}

fn reject_bitcast_paddr_to_int(p: PAddr) -> usize {
    // Stripping the address class out via bitcast is also gated.
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    return bitcast<usize>(p);
}

// ---- KEYSTONE: the forged device write must not type-check ----

fn reject_forged_device_write(n: usize, b: u32) -> void {
    // EXPECT_ERROR: E_ADDRESS_CLASS_CAST
    let p = n as MmioPtr<Dev>;
    p.data.write(b, .release);
}

// ---- BY-DESIGN ACCEPTS — these MUST still compile (the audited boundary) ----

// EXTRACT: address class -> usize (the pa_value/va_value raw-access edge).
fn accept_paddr_to_usize(p: PAddr) -> usize {
    return p as usize;
}

fn accept_vaddr_to_usize(v: VAddr) -> usize {
    return v as usize;
}

fn accept_dma_to_usize(d: DmaAddr) -> usize {
    return d as usize;
}

fn accept_userptr_to_usize(u: UserPtr<u8>) -> usize {
    return u as usize;
}

// IDENTITY: same-class cast extracts/forges nothing.
fn accept_paddr_identity(p: PAddr) -> PAddr {
    return p as PAddr;
}

// UNSAFE ESCAPE: the controlled mint/cross the typed constructors and uaccess use.
fn accept_mint_in_unsafe(n: usize) -> VAddr {
    var v: VAddr = uninit;
    unsafe { v = n as VAddr; }
    return v;
}

fn accept_cross_in_unsafe(p: PAddr) -> VAddr {
    var v: VAddr = uninit;
    unsafe { v = (p as usize) as VAddr; }
    return v;
}

fn accept_forge_mmio_in_unsafe(n: usize) -> MmioPtr<Dev> {
    var p: MmioPtr<Dev> = uninit;
    unsafe { p = n as MmioPtr<Dev>; }
    return p;
}
