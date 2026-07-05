// kernel/core/bootinfo — the architecture-neutral BootInfo contract
// (docs/platform-portability-plan.md §3.1). Every architecture normalizes its
// firmware input (FDT on RISC-V/AArch64, ACPI+Limine/Multiboot on x86_64) into
// ONE structure so the rest of the kernel discovers RAM + console + devices
// without hardcoded addresses or per-arch knowledge.
//
// This file is CORE, not arch: it depends only on std + kernel/core/fdt.mc and
// must never import a kernel/arch/* file. The arch boot runtime calls
// `bootinfo_from_fdt` (RISC-V/AArch64); an x86_64 builder would live beside it
// later and produce the same struct.
//
// Honesty: only the §3.1 fields that have a REAL consumer NOW are populated.
// Deferred §3.1 fields (no consumer yet, so no speculative abstraction):
//   - kernel_image_range : needs the linker-script image bounds plumbed in.
//   - initrd_or_modules  : QEMU virt boot here passes no initrd.
//   - acpi_pointer       : ACPI is an x86_64/AArch64-with-UEFI concern, not FDT virt.
//   - command_line       : /chosen bootargs not consumed by any subsystem yet.
//   - cpu_count          : needs a /cpus walk; only boot_cpu_id has a consumer now.
//   - platform_name      : /compatible string not consumed yet.
// Each gets a field the day it gets a consumer — not before.

import "kernel/core/fdt.mc";
import "std/addr.mc";

// A [base, base+size) physical range, kept as plain u64s so the struct is
// ABI-trivial to return by value and copy across the boot seam.
pub struct MemRange {
    base: u64,
    size: u64,
}

// The normalized firmware contract. Architecture-neutral by construction: every
// field is a plain scalar / MemRange, nothing arch-specific leaks in.
pub struct BootInfo {
    boot_cpu_id: u64,        // the hart/CPU id the firmware booted us on
    fdt_pointer: u64,        // raw physical address of the device tree (0 if none)
    memory: MemRange,        // primary usable RAM range from /memory
    console_base: u64,       // UART MMIO base (0 if not found)
    plic_base: u64,          // interrupt-controller base (0 if not found)
    virtio_mmio_first: u64,  // first virtio-mmio node base in tree order (0 if none)
    virtio_mmio_count: u32,  // number of virtio-mmio nodes discovered
    mem_found: bool,         // did /memory yield a usable range?
}

// A fully-zeroed BootInfo with mem_found=false — the fail-closed result when the
// DTB is missing/invalid. Callers treat mem_found=false as "trust nothing here".
fn bootinfo_zero() -> BootInfo {
    return .{
        .boot_cpu_id = 0,
        .fdt_pointer = 0,
        .memory = .{ .base = 0, .size = 0 },
        .console_base = 0,
        .plic_base = 0,
        .virtio_mmio_first = 0,
        .virtio_mmio_count = 0,
        .mem_found = false,
    };
}

// Build the normalized BootInfo from a device tree. This is the REAL, first
// consumer of the BootInfo contract.
//
// Fail-closed: if the DTB header is unreadable / has the wrong magic, return a
// zeroed BootInfo (mem_found=false) rather than trusting garbage. Otherwise the
// blob length is taken from the FDT header's totalsize, and every field is filled
// by the existing kernel/core/fdt.mc walkers. Pure MC, no `unsafe`.
pub fn bootinfo_from_fdt(dtb: PAddr, boot_cpu_id: u64) -> BootInfo {
    // An 8-byte window reaches magic@0 and totalsize@4; that's all we need to
    // validate the header and learn the true blob length.
    if !fdt_valid(dtb, 8) {
        return bootinfo_zero();
    }
    let total: usize = fdt_totalsize(dtb, 8) as usize;

    var out: BootInfo = bootinfo_zero();
    out.boot_cpu_id = boot_cpu_id;
    out.fdt_pointer = pa_value(dtb) as u64;

    let m: FdtMemory = fdt_memory(dtb, total);
    out.mem_found = m.found;
    out.memory = .{ .base = m.base, .size = m.size };

    let uart: FdtDevice = fdt_find_uart(dtb, total);
    out.console_base = uart.base;

    let plic: FdtDevice = fdt_find_plic(dtb, total);
    out.plic_base = plic.base;

    let v: FdtDevice = fdt_first_virtio_mmio(dtb, total);
    out.virtio_mmio_first = v.base;
    out.virtio_mmio_count = fdt_count_virtio_mmio(dtb, total);

    return out;
}

// ----- scalar accessors for the C boot runtime (clean C/MC ABI) -----
//
// Rather than expose MC struct layout across the C ABI, the S-mode boot runtime
// asks for each field separately (mirrors fdt_boot_*_pa / fdt_*_base_pa). The
// fixture wraps the raw dtb usize into a PAddr and delegates here. Each call
// rebuilds the BootInfo: cheap relative to a real boot, and keeps the C side
// free of any layout assumptions.

export fn bootinfo_cpu_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.boot_cpu_id;
}
export fn bootinfo_fdt_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.fdt_pointer;
}
export fn bootinfo_mem_base_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.memory.base;
}
export fn bootinfo_mem_size_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.memory.size;
}
export fn bootinfo_console_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.console_base;
}
export fn bootinfo_plic_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.plic_base;
}
export fn bootinfo_virtio_first_pa(dtb: PAddr, boot_cpu_id: u64) -> u64 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.virtio_mmio_first;
}
export fn bootinfo_virtio_count_pa(dtb: PAddr, boot_cpu_id: u64) -> u32 {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.virtio_mmio_count;
}
export fn bootinfo_mem_found_pa(dtb: PAddr, boot_cpu_id: u64) -> bool {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return bi.mem_found;
}
