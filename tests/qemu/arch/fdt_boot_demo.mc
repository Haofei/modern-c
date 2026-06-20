// Fixture for the fdt-boot gate: the OpenSBI S-mode runtime passes the DTB physical
// address (OpenSBI's a1) as a plain integer across the C ABI; we wrap it into a PAddr
// and ask kernel/core/fdt.mc to walk the structure block for the /memory node. The blob
// length is taken from the FDT header's totalsize field (read with an 8-byte window,
// which is enough to reach the totalsize@4 field).

import "kernel/core/fdt.mc";
import "std/addr.mc";

export fn fdt_boot_base(dtb: usize) -> u64 {
    return fdt_boot_base_pa(pa(dtb));
}
export fn fdt_boot_size(dtb: usize) -> u64 {
    return fdt_boot_size_pa(pa(dtb));
}
export fn fdt_boot_ok(dtb: usize) -> bool {
    return fdt_boot_ok_pa(pa(dtb));
}
