// MC standard library — `dma`: DMA buffer ownership (section 18.2), built on the
// linear `move` qualifier (section 18.1). The cpu-owned / device-owned typestate
// is two distinct `move` types: a buffer is *either* a `CpuBuffer` (the CPU may
// read/write it) *or* a `DeviceBuffer` (handed to the device). The transitions
// consume one and produce the other, so the compiler rejects:
//   - reading a device-owned buffer  → type error (cpu_addr takes *CpuBuffer)
//   - using a buffer after handoff   → E_USE_AFTER_MOVE
//   - dropping a buffer un-freed      → E_RESOURCE_LEAK
//
// `cpu_addr`/`device_addr`/`len` borrow (`&buf`); transitions and `free` consume.
// alloc/free and the cache maintenance are platform primitives.

move struct CpuBuffer {
    dev_addr: usize, // device-visible (bus) address
    cpu_addr: usize, // CPU-visible address
    len: usize,
}

move struct DeviceBuffer {
    dev_addr: usize,
    len: usize,
}

extern fn mc_dma_alloc(len: usize) -> CpuBuffer;
extern fn mc_dma_free(b: CpuBuffer) -> void;
extern fn mc_dma_clean_for_device(b: CpuBuffer) -> DeviceBuffer;   // clean caches, hand to device
extern fn mc_dma_invalidate_for_cpu(b: DeviceBuffer) -> CpuBuffer; // invalidate caches, take back

// Allocate a coherent/cpu-owned DMA buffer of `len` bytes (linear handle).
export fn alloc(len: usize) -> CpuBuffer {
    return mc_dma_alloc(len);
}

// Free a cpu-owned buffer, consuming it.
export fn free(b: CpuBuffer) -> void {
    mc_dma_free(b);
}

// Hand the buffer to the device: clean (flush) caches, consume the CpuBuffer,
// produce a DeviceBuffer. After this the CPU may not touch the buffer.
export fn clean_for_device(b: CpuBuffer) -> DeviceBuffer {
    return mc_dma_clean_for_device(b);
}

// Take the buffer back: invalidate caches, consume the DeviceBuffer, produce a
// CpuBuffer the CPU may read.
export fn invalidate_for_cpu(b: DeviceBuffer) -> CpuBuffer {
    return mc_dma_invalidate_for_cpu(b);
}

// Device address — readable in either state (borrows, does not consume).
export fn device_addr(b: *DeviceBuffer) -> usize {
    return b.dev_addr;
}

// CPU address — readable only while cpu-owned (the param type enforces it).
export fn cpu_addr(b: *CpuBuffer) -> usize {
    return b.cpu_addr;
}

export fn cpu_len(b: *CpuBuffer) -> usize {
    return b.len;
}

// ----- typed byte view (cpu-owned only) -----
//
// The CPU may read/write a buffer only while it owns it: these take a
// `*CpuBuffer` (not a DeviceBuffer), so touching device-owned memory is a type
// error. The raw memory access is concentrated here behind a typed, bounds-
// checked API — drivers never open-code `raw.store`/`raw.load`. Out-of-bounds
// offsets trap. Multi-byte accessors are big-endian (network order); little-
// endian variants follow the same shape.

export fn write_u8(b: *CpuBuffer, offset: usize, value: u8) -> void {
    if offset >= b.len {
        unreachable; // out of bounds
    }
    unsafe {
        raw.store<u8>(phys(b.cpu_addr + offset), value);
    }
}

export fn read_u8(b: *CpuBuffer, offset: usize) -> u8 {
    if offset >= b.len {
        unreachable; // out of bounds
    }
    unsafe {
        return raw.load<u8>(phys(b.cpu_addr + offset));
    }
}

export fn write_be16(b: *CpuBuffer, offset: usize, value: u16) -> void {
    write_u8(b, offset, (value >> 8) as u8);
    write_u8(b, offset + 1, (value & 0x00FF) as u8);
}

export fn read_be16(b: *CpuBuffer, offset: usize) -> u16 {
    let hi: u16 = read_u8(b, offset) as u16;
    let lo: u16 = read_u8(b, offset + 1) as u16;
    return (hi << 8) | lo;
}

export fn write_be32(b: *CpuBuffer, offset: usize, value: u32) -> void {
    write_u8(b, offset, (value >> 24) as u8);
    write_u8(b, offset + 1, ((value >> 16) & 0x0000_00FF) as u8);
    write_u8(b, offset + 2, ((value >> 8) & 0x0000_00FF) as u8);
    write_u8(b, offset + 3, (value & 0x0000_00FF) as u8);
}

export fn read_be32(b: *CpuBuffer, offset: usize) -> u32 {
    let b0: u32 = read_u8(b, offset) as u32;
    let b1: u32 = read_u8(b, offset + 1) as u32;
    let b2: u32 = read_u8(b, offset + 2) as u32;
    let b3: u32 = read_u8(b, offset + 3) as u32;
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}
