// Regression: two MMIO register reads joined by a binary operator must BOTH be hoisted to
// sequenced temps. collectMmioReadHoistsForExpr's `.binary` arm previously used a
// short-circuiting `or` over its operands, so once the LEFT operand registered a read the
// RIGHT operand was never visited — leaving the right read to fall through the generic
// expression path, which cannot emit the `.read(.<ordering>)` argument (a target-less enum
// literal) and aborted with UnsupportedCEmission. Exercises the pattern in both a `return`
// and an `if` condition, which is exactly how a virtio device probe scans its mmio window
// (`slot.magic.read(.acquire) == MAGIC && slot.device_id.read(.acquire) == ID`).

extern mmio struct ProbeMmio {
    magic: Reg<u32, .read>      @offset(0x000),
    device_id: Reg<u32, .read>  @offset(0x008),
}

const MAGIC: u32 = 0x7472_6976;
const DEVICE_ID: u32 = 4;

// `&&` of two reads in a return-expression position.
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
