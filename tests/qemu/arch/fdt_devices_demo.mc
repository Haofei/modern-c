// Fixture for the fdt-devices gate (Phase R5 device discovery). The OpenSBI
// S-mode runtime passes the DTB physical address (OpenSBI's a1) as a plain
// integer across the C ABI; we wrap it into a PAddr and ask kernel/core/fdt.mc
// to walk the structure block for each device class by `compatible` string,
// decoding `reg` with the parent node's #address-cells/#size-cells. The blob
// length is taken from the FDT header's totalsize field inside the kernel
// entry points (an 8-byte window reaches totalsize@4).

import "kernel/core/fdt.mc";
import "std/addr.mc";

export fn fdt_dev_uart_base(dtb: usize) -> u64 {
    return fdt_uart_base_pa(pa(dtb));
}
export fn fdt_dev_plic_base(dtb: usize) -> u64 {
    return fdt_plic_base_pa(pa(dtb));
}
export fn fdt_dev_virtio_first_base(dtb: usize) -> u64 {
    return fdt_virtio_first_base_pa(pa(dtb));
}
export fn fdt_dev_virtio_count(dtb: usize) -> u32 {
    return fdt_virtio_count_pa(pa(dtb));
}
