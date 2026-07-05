// Reusable RISC-V S-mode PLIC dispatch shell.
//
// This layer intentionally does not keep a table of handler function pointers:
// MC forbids indirect calls in `#[irq_context]`, and interrupt handlers should
// stay explicit about which device source they are servicing. The helper carries
// the S-mode PLIC context and centralizes the claim/complete path so S-mode
// demos and drivers do not open-code context selection.

import "kernel/drivers/irq/plic.mc";

const SCAUSE_S_EXT: u64 = 0x8000_0000_0000_0009;

pub struct SModePlic {
    base: usize,
    ctx: PlicContext,
}

#[irq_context]
pub fn smode_plic_for_hart(base: usize, hart: u32) -> SModePlic {
    return .{ .base = base, .ctx = plic_s_context(hart) };
}

pub fn smode_plic_is_external(scause: u64) -> bool {
    return scause == SCAUSE_S_EXT;
}

pub fn smode_plic_enable_line(d: SModePlic, line: u32, prio: u32, threshold: u32) -> void {
    setup_line_in_context(d.base, d.ctx, line, prio, threshold);
}

#[irq_context]
pub fn smode_plic_claim(d: SModePlic) -> u32 {
    return claim_context(d.base, d.ctx);
}

#[irq_context]
pub fn smode_plic_complete(d: SModePlic, line: u32) -> void {
    complete_context(d.base, d.ctx, line);
}
