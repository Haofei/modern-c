// VisionFive 2 board-readiness adapter.
//
// This does not pretend QEMU `virt` is the StarFive board. It checks whether the
// selected VisionFive 2 profile is still FDT-driven and whether a firmware DTB
// supplies the resource classes that the real board path will need: memory,
// console UART, interrupt controller, and storage/network-class MMIO devices.
// The QEMU gate is a surrogate for that boot contract until real hardware is
// available.

import "kernel/core/bootinfo.mc";
import "kernel/platform/starfive_visionfive2/profile.mc";
import "std/addr.mc";

enum VisionFive2ReadinessCode {
    Ready,
    StaticProfileUnexpected,
    MissingFdt,
    MissingMemory,
    MissingConsole,
    MissingInterruptController,
    MissingStorageOrNetwork,
}

struct VisionFive2Readiness {
    ready: bool,
    code: VisionFive2ReadinessCode,
    boot_cpu_id: u64,
    fdt_pointer: u64,
    console_base: u64,
    plic_base: u64,
    virtio_mmio_count: u32,
}

fn readiness_result(bi: BootInfo, code: VisionFive2ReadinessCode, ready: bool) -> VisionFive2Readiness {
    return .{
        .ready = ready,
        .code = code,
        .boot_cpu_id = bi.boot_cpu_id,
        .fdt_pointer = bi.fdt_pointer,
        .console_base = bi.console_base,
        .plic_base = bi.plic_base,
        .virtio_mmio_count = bi.virtio_mmio_count,
    };
}

export fn visionfive2_readiness_from_bootinfo(bi: BootInfo) -> VisionFive2Readiness {
    let profile: RiscvBoardProfile = selected_riscv_profile();
    if selected_riscv_profile_ready_for_static_resources() {
        return readiness_result(bi, .StaticProfileUnexpected, false);
    }
    if !profile.requires_fdt {
        return readiness_result(bi, .StaticProfileUnexpected, false);
    }
    if bi.fdt_pointer == 0 {
        return readiness_result(bi, .MissingFdt, false);
    }
    if !bi.mem_found {
        return readiness_result(bi, .MissingMemory, false);
    }
    if bi.console_base == 0 {
        return readiness_result(bi, .MissingConsole, false);
    }
    if bi.plic_base == 0 {
        return readiness_result(bi, .MissingInterruptController, false);
    }
    // In the QEMU surrogate, two or more virtio-mmio devices stand in for the
    // production storage + network resource classes. The real board path will
    // validate its DTB-compatible devices instead of requiring virtio.
    if bi.virtio_mmio_count < 2 {
        return readiness_result(bi, .MissingStorageOrNetwork, false);
    }
    return readiness_result(bi, .Ready, true);
}

export fn visionfive2_qemu_surrogate_readiness(dtb: PAddr, boot_cpu_id: u64) -> VisionFive2Readiness {
    let bi: BootInfo = bootinfo_from_fdt(dtb, boot_cpu_id);
    return visionfive2_readiness_from_bootinfo(bi);
}
