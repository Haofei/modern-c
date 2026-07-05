// StarFive VisionFive 2 production-candidate board profile.
//
// This is the first real RISC-V board target for the appliance-kernel path. It
// deliberately records board identity and required device classes while leaving
// concrete MMIO/IRQ resources to the board DTB: the VisionFive 2 has revisioned
// DTBs, and the existing kernel FDT path is the right source of truth for UART,
// interrupt controller, storage, and network resources.

pub enum RiscvBoardId {
    StarFiveVisionFive2,
}

pub enum RiscvBootChain {
    OpenSbiSMode,
}

pub enum BoardResourceSource {
    FixedProfile,
    DeviceTree,
}

pub struct RiscvBoardProfile {
    board: RiscvBoardId,
    boot_chain: RiscvBootChain,
    hart_count: u32,
    debug_uart_base: u64,
    debug_uart_clock_hz: u32,
    uart_source: BoardResourceSource,
    interrupt_source: BoardResourceSource,
    storage_source: BoardResourceSource,
    network_source: BoardResourceSource,
    requires_sbi_time: bool,
    requires_sbi_reset: bool,
    requires_fdt: bool,
}

pub fn selected_riscv_board() -> RiscvBoardId {
    return .StarFiveVisionFive2;
}

pub fn selected_riscv_board_name() -> *const u8 {
    return "StarFive VisionFive 2";
}

pub fn selected_riscv_soc_compatible() -> *const u8 {
    return "starfive,jh7110";
}

pub fn selected_riscv_board_compatible_v12a() -> *const u8 {
    return "starfive,visionfive-2-v1.2a";
}

pub fn selected_riscv_board_compatible_v13b() -> *const u8 {
    return "starfive,visionfive-2-v1.3b";
}

pub fn selected_riscv_dtb_v12a() -> *const u8 {
    return "starfive/jh7110-starfive-visionfive-2-v1.2a.dtb";
}

pub fn selected_riscv_dtb_v13b() -> *const u8 {
    return "starfive/jh7110-starfive-visionfive-2-v1.3b.dtb";
}

pub fn selected_riscv_profile() -> RiscvBoardProfile {
    return .{
        .board = .StarFiveVisionFive2,
        .boot_chain = .OpenSbiSMode,
        .hart_count = 5,
        .debug_uart_base = 0x1000_0000,
        .debug_uart_clock_hz = 24_000_000,
        .uart_source = .DeviceTree,
        .interrupt_source = .DeviceTree,
        .storage_source = .DeviceTree,
        .network_source = .DeviceTree,
        .requires_sbi_time = true,
        .requires_sbi_reset = true,
        .requires_fdt = true,
    };
}

pub fn selected_riscv_profile_ready_for_static_resources() -> bool {
    return false;
}
