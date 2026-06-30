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

import "addr.mc";

move struct CpuBuffer {
    dev_addr: DmaAddr, // device-visible (bus) address (opaque, not a raw usize)
    cpu_addr: PAddr,   // CPU-visible address (typed: checked offset, no raw `+`)
    len: usize,
}

move struct DeviceBuffer {
    dev_addr: DmaAddr,
    len: usize,
}

extern fn mc_dma_alloc_base(len: usize) -> usize;
// Fallible provider primitive: returns 0 on exhaustion (never traps). It is the single
// source of truth in every provider; the infallible `mc_dma_alloc_base` is just this plus a
// trap on 0. `try_alloc` (below) turns the 0 into a typed `DmaError.OutOfMemory`.
extern fn mc_dma_alloc_base_try(len: usize) -> usize;
extern fn mc_dma_free_base(dev_addr: DmaAddr, cpu_addr: PAddr, len: usize) -> void;
extern fn mc_dma_clean_for_device_base(dev_addr: DmaAddr, cpu_addr: PAddr, len: usize) -> void;
extern fn mc_dma_invalidate_for_cpu_base(dev_addr: DmaAddr, len: usize) -> usize;

// Why a non-trapping DMA allocation could not be satisfied. Production broker/device paths
// use `try_alloc` to turn pool exhaustion into this typed error instead of trapping.
enum DmaError {
    OutOfMemory, // the DMA pool had no room for `len` bytes (or its single buffer is in use)
}

// Allocate a coherent/cpu-owned DMA buffer of `len` bytes (linear handle).
export fn alloc(len: usize) -> CpuBuffer {
    let base: usize = mc_dma_alloc_base(len);
    // Mint the device-address class from the allocator's raw base (audited DMA boundary).
    var dev: DmaAddr = uninit;
    unsafe { dev = (base as usize) as DmaAddr; }
    return .{ .dev_addr = dev, .cpu_addr = pa(base), .len = len };
}

// Fallible allocation: returns a typed `DmaError.OutOfMemory` on pool exhaustion instead of
// trapping. Mints the `CpuBuffer` exactly like `alloc` when the provider returns a non-zero
// base. For production broker/device paths that must degrade gracefully under load.
export fn try_alloc(len: usize) -> Result<CpuBuffer, DmaError> {
    let base: usize = mc_dma_alloc_base_try(len);
    if base == 0 {
        return err(.OutOfMemory);
    }
    // Mint the device-address class from the allocator's raw base (audited DMA boundary).
    var dev: DmaAddr = uninit;
    unsafe { dev = (base as usize) as DmaAddr; }
    return ok(.{ .dev_addr = dev, .cpu_addr = pa(base), .len = len });
}

// Free a cpu-owned buffer, consuming it.
export fn free(b: CpuBuffer) -> void {
    let dev: DmaAddr = b.dev_addr;
    let cpu: PAddr = b.cpu_addr;
    let n: usize = b.len;
    mc_dma_free_base(dev, cpu, n);
    unsafe { forget_unchecked(b); }
}

// Hand the buffer to the device: clean (flush) caches, consume the CpuBuffer,
// produce a DeviceBuffer. After this the CPU may not touch the buffer.
export fn clean_for_device(b: CpuBuffer) -> DeviceBuffer {
    let dev: DmaAddr = b.dev_addr;
    let cpu: PAddr = b.cpu_addr;
    let n: usize = b.len;
    mc_dma_clean_for_device_base(dev, cpu, n);
    unsafe { forget_unchecked(b); }
    return .{ .dev_addr = dev, .len = n };
}

// Take the buffer back: invalidate caches, consume the DeviceBuffer, produce a
// CpuBuffer the CPU may read.
export fn invalidate_for_cpu(b: DeviceBuffer) -> CpuBuffer {
    let dev: DmaAddr = b.dev_addr;
    let n: usize = b.len;
    let cpu: usize = mc_dma_invalidate_for_cpu_base(dev, n);
    unsafe { forget_unchecked(b); }
    return .{ .dev_addr = dev, .cpu_addr = pa(cpu), .len = n };
}

// Device address — readable in either state (borrows, does not consume). Typed
// `DmaAddr` (the device's bus address), distinct from a CPU `PAddr`.
export fn device_addr(b: *DeviceBuffer) -> DmaAddr {
    return b.dev_addr;
}

// CPU address — readable only while cpu-owned (the param type enforces it). Typed
// `PAddr`, so callers can't do unchecked pointer math on it.
export fn cpu_addr(b: *CpuBuffer) -> PAddr {
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

// Bounds-check a `[offset, offset+n)` access against the buffer, overflow-safe. Multi-byte
// writers call this up front so an out-of-bounds access traps *before* any partial store.
fn cpu_check(b: *CpuBuffer, offset: usize, n: usize) -> void {
    if offset > b.len {
        unreachable; // out of bounds
    }
    let room: usize = b.len - offset;
    if n > room {
        unreachable; // out of bounds
    }
}

export fn write_u8(b: *CpuBuffer, offset: usize, value: u8) -> void {
    if offset >= b.len {
        unreachable; // out of bounds
    }
    unsafe {
        raw.store<u8>(pa_offset(b.cpu_addr, offset), value);
    }
}

export fn read_u8(b: *CpuBuffer, offset: usize) -> u8 {
    if offset >= b.len {
        unreachable; // out of bounds
    }
    unsafe {
        return raw.load<u8>(pa_offset(b.cpu_addr, offset));
    }
}

export fn write_be16(b: *CpuBuffer, offset: usize, value: u16) -> void {
    cpu_check(b, offset, 2); // full-width check up front: no partial store before a trap
    write_u8(b, offset, (value >> 8) as u8);
    write_u8(b, offset + 1, (value & 0x00FF) as u8);
}

export fn read_be16(b: *CpuBuffer, offset: usize) -> u16 {
    let hi: u16 = read_u8(b, offset) as u16;
    let lo: u16 = read_u8(b, offset + 1) as u16;
    return (hi << 8) | lo;
}

export fn write_be32(b: *CpuBuffer, offset: usize, value: u32) -> void {
    cpu_check(b, offset, 4); // full-width check up front: no partial store before a trap
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

// Little-endian accessors (virtio structures are little-endian).

export fn write_le16(b: *CpuBuffer, offset: usize, value: u16) -> void {
    cpu_check(b, offset, 2); // full-width check up front: no partial store before a trap
    write_u8(b, offset, (value & 0x00FF) as u8);
    write_u8(b, offset + 1, (value >> 8) as u8);
}

export fn write_le32(b: *CpuBuffer, offset: usize, value: u32) -> void {
    cpu_check(b, offset, 4); // full-width check up front: no partial store before a trap
    write_u8(b, offset, (value & 0x0000_00FF) as u8);
    write_u8(b, offset + 1, ((value >> 8) & 0x0000_00FF) as u8);
    write_u8(b, offset + 2, ((value >> 16) & 0x0000_00FF) as u8);
    write_u8(b, offset + 3, (value >> 24) as u8);
}

export fn write_le64(b: *CpuBuffer, offset: usize, value: u64) -> void {
    cpu_check(b, offset, 8); // full-width check up front: no partial store before a trap
    write_le32(b, offset, (value & 0x0000_0000_FFFF_FFFF) as u32);
    write_le32(b, offset + 4, (value >> 32) as u32);
}

export fn read_le32(b: *CpuBuffer, offset: usize) -> u32 {
    let b0: u32 = read_u8(b, offset) as u32;
    let b1: u32 = read_u8(b, offset + 1) as u32;
    let b2: u32 = read_u8(b, offset + 2) as u32;
    let b3: u32 = read_u8(b, offset + 3) as u32;
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}
