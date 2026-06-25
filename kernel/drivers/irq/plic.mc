// kernel/drivers/irq/plic — RISC-V PLIC (platform-level interrupt controller) as
// a linear IRQ-line typestate. A line moves Unclaimed → Enabled → Pending →
// Enabled, and `complete` (acknowledge) only accepts a `Pending` line — so you
// cannot acknowledge an interrupt that has not been claimed. PLIC register access
// is concentrated in the small raw helpers; the typed layer above is portable in
// shape (an ARM GIC port keeps the same typestate).

// QEMU virt / SiFive-style PLIC layout. Context 0 is hart 0 M-mode; context 1 is
// hart 0 S-mode. Lines < 32 in the current callers, so one enable word is enough.
const PLIC_PRIORITY: usize = 0x0000;             // + line*4
const PLIC_ENABLE_BASE: usize = 0x2000;          // + context*0x80
const PLIC_ENABLE_STRIDE: usize = 0x80;
const PLIC_CONTEXT_BASE: usize = 0x200000;       // + context*0x1000
const PLIC_CONTEXT_STRIDE: usize = 0x1000;
const PLIC_THRESHOLD_OFFSET: usize = 0;
const PLIC_CLAIM_OFFSET: usize = 4;

struct PlicContext {
    id: u32,
}

#[irq_context]
export fn plic_m_context(hart: u32) -> PlicContext {
    return .{ .id = hart * 2 };
}

#[irq_context]
export fn plic_s_context(hart: u32) -> PlicContext {
    return .{ .id = hart * 2 + 1 };
}

fn plic_enable_addr(base: usize, ctx: PlicContext) -> usize {
    return base + PLIC_ENABLE_BASE + (ctx.id as usize) * PLIC_ENABLE_STRIDE;
}

fn plic_threshold_addr(base: usize, ctx: PlicContext) -> usize {
    return base + PLIC_CONTEXT_BASE + (ctx.id as usize) * PLIC_CONTEXT_STRIDE + PLIC_THRESHOLD_OFFSET;
}

#[irq_context]
fn plic_claim_addr(base: usize, ctx: PlicContext) -> usize {
    return base + PLIC_CONTEXT_BASE + (ctx.id as usize) * PLIC_CONTEXT_STRIDE + PLIC_CLAIM_OFFSET;
}

fn plic_set_priority(base: usize, line: u32, prio: u32) -> void {
    unsafe {
        raw.store<u32>(phys(base + PLIC_PRIORITY + (line as usize) * 4), prio);
    }
}

fn plic_enable_line(base: usize, ctx: PlicContext, line: u32) -> void {
    unsafe {
        let addr: usize = plic_enable_addr(base, ctx);
        let cur: u32 = raw.load<u32>(phys(addr));
        raw.store<u32>(phys(addr), cur | ((1 as u32) << line));
    }
}

fn plic_disable_line(base: usize, ctx: PlicContext, line: u32) -> void {
    unsafe {
        let addr: usize = plic_enable_addr(base, ctx);
        let cur: u32 = raw.load<u32>(phys(addr));
        raw.store<u32>(phys(addr), cur & ~((1 as u32) << line));
        raw.store<u32>(phys(base + PLIC_PRIORITY + (line as usize) * 4), 0); // priority 0 = never fires
    }
}

fn plic_set_threshold(base: usize, ctx: PlicContext, threshold: u32) -> void {
    unsafe {
        raw.store<u32>(phys(plic_threshold_addr(base, ctx)), threshold);
    }
}

// Marked `#[irq_context]`: these are trivial raw-register accessors with no blocking
// work, so they are safe to call from the `#[irq_context]` claim/complete path. The
// attribute makes them legal irq-context callees under the reconciled discipline
// (sema `E_IRQ_CONTEXT_CALL` and the MIR verifier now agree).
#[irq_context]
fn plic_claim(base: usize, ctx: PlicContext) -> u32 {
    unsafe {
        return raw.load<u32>(phys(plic_claim_addr(base, ctx)));
    }
}

#[irq_context]
fn plic_complete_raw(base: usize, ctx: PlicContext, line: u32) -> void {
    unsafe {
        raw.store<u32>(phys(plic_claim_addr(base, ctx)), line);
    }
}

// ----- Context-aware raw helpers -----
//
// These are for trap/ISR code that cannot conveniently carry a linear IrqLine
// token across interrupt entries. They still centralize the PLIC context math so
// demos and future S-mode drivers do not open-code context-1 addresses.

export fn setup_line_in_context(base: usize, ctx: PlicContext, line: u32, prio: u32, threshold: u32) -> void {
    plic_set_priority(base, line, prio);
    plic_set_threshold(base, ctx, threshold);
    plic_enable_line(base, ctx, line);
}

#[irq_context]
export fn claim_context(base: usize, ctx: PlicContext) -> u32 {
    return plic_claim(base, ctx);
}

#[irq_context]
export fn complete_context(base: usize, ctx: PlicContext, line: u32) -> void {
    plic_complete_raw(base, ctx, line);
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
    return enable_in_context(base, plic_m_context(0), l);
}

// Enable the line in an explicit PLIC context.
export fn enable_in_context(base: usize, ctx: PlicContext, l: IrqLine<Unclaimed>) -> IrqLine<Enabled> {
    let line: u32 = l.line;
    plic_set_priority(base, line, 1);
    plic_set_threshold(base, ctx, 0);
    plic_enable_line(base, ctx, line);
    unsafe { forget_unchecked(l); }
    return .{ .line = line };
}

// Claim the highest-priority pending interrupt and transition the line to Pending.
// The claimed source id must match this line — a single-line model where the
// caller asserts this line is the pending source. A mismatch (a different source,
// or 0 = nothing pending) is a contract violation and traps rather than minting a
// bogus Pending token that `complete` would then acknowledge.
//
// C2: this runs inside the interrupt to claim the pending source, so it is
// IRQ/atomic context — the sema rule forbids it from calling any `#[may_sleep]`
// op (heap alloc, mutex_lock, sched_yield). It only touches PLIC registers.
#[irq_context]
export fn claim_if_pending(base: usize, l: IrqLine<Enabled>) -> IrqLine<Pending> {
    return claim_if_pending_in_context(base, plic_m_context(0), l);
}

#[irq_context]
export fn claim_if_pending_in_context(base: usize, ctx: PlicContext, l: IrqLine<Enabled>) -> IrqLine<Pending> {
    let line: u32 = l.line;
    let claimed: u32 = plic_claim(base, ctx);
    if claimed != line {
        unreachable; // claimed source does not match this line
    }
    unsafe { forget_unchecked(l); }
    return .{ .line = line };
}

// Acknowledge a pending interrupt (PLIC complete). Only a Pending line.
export fn complete(base: usize, l: IrqLine<Pending>) -> IrqLine<Enabled> {
    return complete_in_context(base, plic_m_context(0), l);
}

export fn complete_in_context(base: usize, ctx: PlicContext, l: IrqLine<Pending>) -> IrqLine<Enabled> {
    let line: u32 = l.line;
    plic_complete_raw(base, ctx, line);
    unsafe { forget_unchecked(l); }
    return .{ .line = line };
}

// Release the line: actually mask it in the PLIC (clear the enable bit and zero
// its priority) before retiring the token.
export fn release(base: usize, l: IrqLine<Enabled>) -> void {
    release_in_context(base, plic_m_context(0), l);
}

export fn release_in_context(base: usize, ctx: PlicContext, l: IrqLine<Enabled>) -> void {
    plic_disable_line(base, ctx, l.line);
    unsafe { forget_unchecked(l); }
}
