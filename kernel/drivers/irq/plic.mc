// kernel/drivers/irq/plic — RISC-V PLIC (platform-level interrupt controller) as
// a linear IRQ-line typestate. A line moves Unclaimed → Enabled → Pending →
// Enabled, and `complete` (acknowledge) only accepts a `Pending` line — so you
// cannot acknowledge an interrupt that has not been claimed. PLIC register access
// is concentrated in the small raw helpers; the typed layer above is portable in
// shape (an ARM GIC port keeps the same typestate).

// QEMU virt PLIC layout, **machine context 0** (hart 0 M-mode — matching this
// kernel's M-mode CSRs in csr.mc). Lines < 32.
const PLIC_PRIORITY: usize = 0x0000;        // + line*4
const PLIC_ENABLE_M: usize = 0x2000;        // hart 0 M-mode enable bitmap
const PLIC_THRESHOLD_M: usize = 0x200000;   // hart 0 M-mode threshold
const PLIC_CLAIM_M: usize = 0x200004;       // hart 0 M-mode claim/complete

fn plic_set_priority(base: usize, line: u32, prio: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_PRIORITY + (line as usize) * 4), prio);
    }
}

fn plic_enable_line(base: usize, line: u32) -> void {
    unsafe {
        let cur: u32 = raw.load<u32>(phys(base + PLIC_ENABLE_M));
        raw.store<u32>(phys(base + PLIC_ENABLE_M), cur | ((1 as u32) << line));
    }
}

fn plic_disable_line(base: usize, line: u32) -> void {
    unsafe {
        let cur: u32 = raw.load<u32>(phys(base + PLIC_ENABLE_M));
        raw.store<u32>(phys(base + PLIC_ENABLE_M), cur & ~((1 as u32) << line));
        raw.store<u32>(phys(base + PLIC_PRIORITY + (line as usize) * 4), 0); // priority 0 = never fires
    }
}

fn plic_set_threshold(base: usize, threshold: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_THRESHOLD_M), threshold);
    }
}

fn plic_claim(base: usize) -> u32 {
    unsafe {
        return raw.load<u32>(phys(base + PLIC_CLAIM_M));
    }
}

fn plic_complete_raw(base: usize, line: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_CLAIM_M), line);
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
    unsafe { forget_unchecked(l); }
    return .{ .line = line };
}

// Claim the highest-priority pending interrupt and transition the line to Pending.
// The claimed source id must match this line — a single-line model where the
// caller asserts this line is the pending source. A mismatch (a different source,
// or 0 = nothing pending) is a contract violation and traps rather than minting a
// bogus Pending token that `complete` would then acknowledge.
export fn claim_if_pending(base: usize, l: IrqLine<Enabled>) -> IrqLine<Pending> {
    let line: u32 = l.line;
    let claimed: u32 = plic_claim(base);
    if claimed != line {
        unreachable; // claimed source does not match this line
    }
    unsafe { forget_unchecked(l); }
    return .{ .line = line };
}

// Acknowledge a pending interrupt (PLIC complete). Only a Pending line.
export fn complete(base: usize, l: IrqLine<Pending>) -> IrqLine<Enabled> {
    let line: u32 = l.line;
    plic_complete_raw(base, line);
    unsafe { forget_unchecked(l); }
    return .{ .line = line };
}

// Release the line: actually mask it in the PLIC (clear the enable bit and zero
// its priority) before retiring the token.
export fn release(base: usize, l: IrqLine<Enabled>) -> void {
    plic_disable_line(base, l.line);
    unsafe { forget_unchecked(l); }
}
