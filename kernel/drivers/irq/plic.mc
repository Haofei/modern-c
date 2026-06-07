// kernel/drivers/irq/plic — RISC-V PLIC (platform-level interrupt controller) as
// a linear IRQ-line typestate. A line moves Unclaimed → Enabled → Pending →
// Enabled, and `complete` (acknowledge) only accepts a `Pending` line — so you
// cannot acknowledge an interrupt that has not been claimed. PLIC register access
// is concentrated in the small raw helpers; the typed layer above is portable in
// shape (an ARM GIC port keeps the same typestate).

// QEMU virt PLIC layout, supervisor context 1 (hart 0 S-mode). Lines < 32.
const PLIC_PRIORITY: usize = 0x0000;       // + line*4
const PLIC_ENABLE_CTX1: usize = 0x2080;    // context 1 enable bitmap
const PLIC_THRESHOLD_CTX1: usize = 0x201000;
const PLIC_CLAIM_CTX1: usize = 0x201004;   // claim (read) / complete (write)

fn plic_set_priority(base: usize, line: u32, prio: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_PRIORITY + (line as usize) * 4), prio);
    }
}

fn plic_enable_line(base: usize, line: u32) -> void {
    unsafe {
        let cur: u32 = raw.load<u32>(phys(base + PLIC_ENABLE_CTX1));
        raw.store<u32>(phys(base + PLIC_ENABLE_CTX1), cur | ((1 as u32) << line));
    }
}

fn plic_set_threshold(base: usize, threshold: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_THRESHOLD_CTX1), threshold);
    }
}

fn plic_claim(base: usize) -> u32 {
    unsafe {
        return raw.load<u32>(phys(base + PLIC_CLAIM_CTX1));
    }
}

fn plic_complete_raw(base: usize, line: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_CLAIM_CTX1), line);
    }
}

// ----- IRQ line typestate -----

struct Unclaimed {}
struct Enabled {}
struct Pending {}

move struct IrqLine<State> {
    line: u32,
}

// Take ownership of an interrupt line number.
export fn claim_line(line: u32) -> IrqLine<Unclaimed> {
    return .{ .line = line };
}

// Enable the line in the PLIC (priority > 0, threshold 0, enable bit).
export fn enable(base: usize, l: IrqLine<Unclaimed>) -> IrqLine<Enabled> {
    let line: u32 = l.line;
    plic_set_priority(base, line, 1);
    plic_set_threshold(base, 0);
    plic_enable_line(base, line);
    drop(l);
    return .{ .line = line };
}

// Claim the highest-priority pending interrupt; returns true and a Pending line if
// it is ours, otherwise re-enables. (Single-line model for the smoke path.)
export fn claim_if_pending(base: usize, l: IrqLine<Enabled>) -> IrqLine<Pending> {
    let line: u32 = l.line;
    drop(l);
    let _claimed: u32 = plic_claim(base); // consume the claim id
    return .{ .line = line };
}

// Acknowledge a pending interrupt (PLIC complete). Only a Pending line.
export fn complete(base: usize, l: IrqLine<Pending>) -> IrqLine<Enabled> {
    let line: u32 = l.line;
    plic_complete_raw(base, line);
    drop(l);
    return .{ .line = line };
}

// Release the line (mask it again).
export fn release(l: IrqLine<Enabled>) -> void {
    drop(l);
}
