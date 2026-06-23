// Differential-coverage fixture: TYPED MMIO register reads (`Reg`/`RegBits`) in the
// non-trivial syntactic positions that the differential corpus otherwise never exercises
// — the family adjacent to the overlay-read miscompile class (docs/lowering-coverage.md).
// The C and LLVM backends lower a `reg.read(order)` differently depending on where the
// read appears, and the uncovered branches are exactly these positions:
//
//   - inferred-local initializer:   `let d = p.data.read(.relaxed);`  (no type annotation)
//   - call-argument position:       `consume(p.ctrl.read(.relaxed))`
//   - checked-unary operand:        `-(p.small.read(.relaxed) as i32)`
//   - packed-bits mask test:        `if p.flags.read(.acquire).ready { … }`
//
// Host-safe: the device window is a real, 4-byte-aligned global, so the MMIO loads/stores
// address memory the host owns. Entry mode compares the C and LLVM return values, so any
// divergence in how either backend lowers a read in one of these positions makes the two
// outputs disagree (a backend codegen bug) rather than silently passing.

packed bits Status: u8 {
    ready: bool,
    error: bool,
    half: bool,
    full: bool,
    b4: bool,
    b5: bool,
    b6: bool,
    b7: bool,
}

extern mmio struct Dev {
    data: Reg<u32, .read_write>,
    ctrl: Reg<u32, .read_write>,
    flags: RegBits<u8, Status, .read>,
    small: Reg<u8, .read_write>,
}

// A 4-byte-aligned backing window: data@0, ctrl@4, flags@8 (low byte of g_back[2]),
// small@9 (next byte of g_back[2]).
global g_back: [4]u32;

fn consume(x: u32) -> u32 {
    return (x ^ 0x5A5A_5A5A) + 1;
}

export fn mmio_read_positions_run() -> u32 {
    // Prefill the read-only flags byte at offset 8 (low byte of g_back[2]):
    //   0xA5 = 1010_0101 -> ready=1, error=0, half=1, full=0, b4=0, b5=1, b6=0, b7=1
    g_back[2] = 0x0000_00A5;

    var p: MmioPtr<Dev> = uninit;
    unsafe { p = ((&g_back[0]) as usize) as MmioPtr<Dev>; }

    var acc: u32 = 0;

    // (1) inferred-local initializer from an MMIO read
    p.data.write(0x1122_3344, .relaxed);
    let d = p.data.read(.relaxed);
    acc = acc ^ d;

    // (2) MMIO read as a call argument
    p.ctrl.write(0x0F0F_0F0F, .relaxed);
    acc = acc ^ consume(p.ctrl.read(.relaxed));

    // (3) MMIO read as the operand of a checked unary negate
    p.small.write(7, .relaxed);
    let neg: i32 = -(p.small.read(.relaxed) as i32);
    acc = acc ^ (neg as u32);

    // (4) packed-bits field test on an MMIO read, in condition position
    if p.flags.read(.acquire).ready { acc = acc ^ 0x0000_0100; }
    if p.flags.read(.acquire).full { acc = acc ^ 0x0000_0200; }   // full=0 -> not taken
    if p.flags.read(.acquire).b5 { acc = acc ^ 0x0000_0400; }
    if p.flags.read(.acquire).b7 { acc = acc ^ 0x0000_0800; }

    // Both backends must compute the same acc; entry mode diffs C vs LLVM stdout.
    return acc;
}
