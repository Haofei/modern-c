// kernel/platform/qemu_virt/virtio_mmio_hw — board-specific virtio-mmio discovery window.
//
// The QEMU `virt` machine places 8 virtio-mmio device slots at 0x1000_1000 with a
// 0x1000 stride. This geometry is a board fact, not a driver fact, so it lives here and
// is reached through the `kernel/platform/active/` seam; a driver scans the window via
// these accessors rather than hardcoding the address. Imports nothing but builtins so it
// flattens cleanly into any driver object without dragging in std symbols.

export fn plat_virtio_mmio_base() -> usize {
    return 0x1000_1000;
}

export fn plat_virtio_mmio_stride() -> usize {
    return 0x1000;
}

export fn plat_virtio_mmio_count() -> u32 {
    return 8;
}
