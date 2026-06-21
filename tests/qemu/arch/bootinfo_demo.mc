// Fixture for the bootinfo gate (Phase R5b / §3.1 BootInfo). The OpenSBI S-mode
// runtime passes the DTB physical address (OpenSBI's a1) and the boot hartid
// (a0) as plain integers across the C ABI; we wrap the dtb into a PAddr and ask
// kernel/core/bootinfo.mc to normalize the firmware input into the
// architecture-neutral BootInfo contract, then expose each field through a
// scalar accessor (clean C/MC ABI — the C side never sees MC struct layout).

import "kernel/core/bootinfo.mc";
import "std/addr.mc";

export fn bootinfo_demo_cpu(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_cpu_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_fdt(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_fdt_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_mem_base(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_mem_base_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_mem_size(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_mem_size_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_console(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_console_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_plic(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_plic_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_virtio_first(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_virtio_first_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_virtio_count(dtb: usize, hartid: u64) -> u32 {
    return bootinfo_virtio_count_pa(pa(dtb), hartid);
}
export fn bootinfo_demo_mem_found(dtb: usize, hartid: u64) -> bool {
    return bootinfo_mem_found_pa(pa(dtb), hartid);
}
