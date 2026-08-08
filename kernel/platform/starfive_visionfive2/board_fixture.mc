// VisionFive 2 board-resource fixture.
//
// This does not pretend QEMU `virt` is the StarFive board. It checks whether the
// selected VisionFive 2 profile is still FDT-driven and whether a firmware DTB
// supplies the resource classes that the real board path will need: memory,
// console UART, interrupt controller, and storage/network-class MMIO devices.
// The QEMU gate is a language/backend fixture for that boot contract.

import "kernel/core/bootinfo.mc";
import "kernel/platform/starfive_visionfive2/profile.mc";
import "std/addr.mc";

pub enum VisionFive2ResourceCode {
    Available,
    StaticProfileUnexpected,
    MissingFdt,
    MissingMemory,
    MissingConsole,
    MissingInterruptController,
    MissingStorageOrNetwork,
}

pub struct VisionFive2ResourceCheck {
    available: bool,
    code: VisionFive2ResourceCode,
    boot_cpu_id: u64,
    fdt_pointer: u64,
    console_base: u64,
    plic_base: u64,
    virtio_mmio_count: u32,
}

fn resource_result(bi: BootInfo, code: VisionFive2ResourceCode, available: bool) -> VisionFive2ResourceCheck {
    return .{
        .available = available,
        .code = code,
        .boot_cpu_id = bi.boot_cpu_id,
        .fdt_pointer = bi.fdt_pointer,
        .console_base = bi.console_base,
        .plic_base = bi.plic_base,
        .virtio_mmio_count = bi.virtio_mmio_count,
    };
}

pub fn visionfive2_resource_check_from_bootinfo(bi: BootInfo) -> VisionFive2ResourceCheck {
    let profile: RiscvBoardProfile = selected_riscv_profile();
    if selected_riscv_profile_has_static_resources() {
        return resource_result(bi, .StaticProfileUnexpected, false);
    }
    if !profile.requires_fdt {
        return resource_result(bi, .StaticProfileUnexpected, false);
    }
    if bi.fdt_pointer == 0 {
        return resource_result(bi, .MissingFdt, false);
    }
    if !bi.mem_found {
        return resource_result(bi, .MissingMemory, false);
    }
    if bi.console_base == 0 {
        return resource_result(bi, .MissingConsole, false);
    }
    if bi.plic_base == 0 {
        return resource_result(bi, .MissingInterruptController, false);
    }
    // In the QEMU surrogate, two or more virtio-mmio devices stand in for the
    // storage + network resource classes. The real board path will
    // validate its DTB-compatible devices instead of requiring virtio.
    if bi.virtio_mmio_count < 2 {
        return resource_result(bi, .MissingStorageOrNetwork, false);
    }
    return resource_result(bi, .Available, true);
}

pub fn visionfive2_qemu_surrogate_resources(dtb: PAddr, boot_cpu_id: u64) -> VisionFive2ResourceCheck {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return visionfive2_resource_check_from_bootinfo(bi);
}
