// Regression: MMIO register reads combined with binary operators.
//
// Two failure modes, both covered here:
//
//  1. collectMmioReadHoistsForExpr's `.binary` arm once used a short-circuiting `or` over its
//     operands, so once the LEFT operand registered a read the RIGHT operand was never visited
//     — the right read fell through the generic path, which cannot emit a target-less
//     `.read(.<ordering>)` enum-literal arg and aborted with UnsupportedCEmission.
//
//  2. Fixing (1) by hoisting BOTH operands then broke `&&` / `||` SHORT-CIRCUIT: hoisting the
//     right operand's read to a temp before the whole expression executes it unconditionally,
//     which is wrong for device registers (a read can ack an IRQ, pop a queue, clear status).
//
// The correct lowering: for short-circuiting `&&` / `||`, the operands' reads are NOT hoisted
// — they render inline (an `.acquire` read becomes a statement-expression carrying its fence)
// at their syntactic position, so C's `&&`/`||` guarantees the right read happens only when
// the left did not already decide the result. For NON-logical binaries (both operands always
// evaluate) the reads are still hoisted to sequenced temps. This is exactly a virtio device
// probe scan: `slot.magic.read(.acquire) == MAGIC && slot.device_id.read(.acquire) == ID`.

extern mmio struct ProbeMmio {
    magic: Reg<u32, .read>      @offset(0x000),
    device_id: Reg<u32, .read>  @offset(0x008),
}

const MAGIC: u32 = 0x7472_6976;
const DEVICE_ID: u32 = 4;

// `&&` of two reads in a return position — the device_id read must be emitted INSIDE the
// `&&` right operand (short-circuit), not before the return.
export fn probe_return(slot: MmioPtr<ProbeMmio>) -> bool {
    return slot.magic.read(.acquire) == MAGIC && slot.device_id.read(.acquire) == DEVICE_ID;
}

// `&&` of two reads in an if-condition position.
export fn probe_if(slot: MmioPtr<ProbeMmio>) -> bool {
    if slot.magic.read(.acquire) == MAGIC && slot.device_id.read(.acquire) == DEVICE_ID {
        return true;
    }
    return false;
}

// `||` short-circuit: the second read must not execute when the first already matched.
export fn probe_or(slot: MmioPtr<ProbeMmio>) -> bool {
    return slot.magic.read(.acquire) == MAGIC || slot.device_id.read(.acquire) == DEVICE_ID;
}

// Non-logical binary (`==`) comparing two reads: BOTH operands always evaluate, so both reads
// are legitimately hoisted to sequenced temps (the case fix (1) correctly enabled).
export fn probe_eq(slot: MmioPtr<ProbeMmio>) -> bool {
    return slot.magic.read(.acquire) == slot.device_id.read(.acquire);
}
