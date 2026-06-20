// Differential-coverage fixture: overlay unions (byte-aliasing storage). Unlike MMIO offset
// structs these ARE host-runnable, so the entry constructs them, writes the scalar member, reads
// the aliased views back, and folds them into a u32 — both backends must agree on the overlay
// layout (storage size + byte aliasing). `sizeof` of each overlay is also folded so the
// `comptimeStructLayout` size path is observed.
//
// READ FORMS PINNED HERE (regression coverage for the overlay-member-read lowering fix):
//   - scalar member read in EXPRESSION position (`(w.u as u64)`, arithmetic/initializer operand),
//     not only the direct-return position that used to be the sole lowered form;
//   - byte-array view read (`w.bytes[i]`) in expression position;
//   - non-byte array view read AND write (`w.halves[i]` where `halves: [2]u16`), which previously
//     never lowered in any position.
// Bare member reads are exercised directly (no accessor-fn indirection) so the fixture pins the
// generalized expression-position path on both backends.

overlay union Word {
    u: u32,
    bytes: [4]u8,
    halves: [2]u16,
}

overlay union WideWord {
    q: u64,
    octets: [8]u8,
    pairs: [4]u16,
}

export fn entry() -> u32 {
    var acc: u64 = 0;

    var w: Word = uninit;
    w.u = 0x11223344;
    // Scalar member read in expression position (cast operand inside an xor).
    acc = (acc ^ (w.u as u64));
    // Byte-view reads in expression position.
    acc = (acc ^ ((w.bytes[0] as u64) << 8));
    acc = (acc ^ ((w.bytes[3] as u64) << 16));
    // Non-byte view read (`[2]u16`) in expression position, both elements.
    acc = (acc ^ ((w.halves[0] as u64) << 1));
    acc = (acc ^ ((w.halves[1] as u64) << 2));
    // Non-byte view write, then read back: overwrite halves[1] and re-read.
    w.halves[1] = 0xBEEF;
    let hi: u64 = (w.halves[1] as u64);
    acc = (acc ^ (hi << 6));
    acc = (acc ^ ((sizeof(Word) as u64) << 4));

    var q: WideWord = uninit;
    q.q = 0x0102030405060708;
    acc = (acc ^ (q.q as u64));
    acc = (acc ^ ((q.octets[7] as u64) << 3));
    acc = (acc ^ ((q.pairs[2] as u64) << 7));
    // Non-byte view write into the wide overlay.
    q.pairs[0] = 0xCAFE;
    acc = (acc ^ ((q.pairs[0] as u64) << 9));
    acc = (acc ^ ((sizeof(WideWord) as u64) << 5));

    // Check the folded overlay reads/writes + sizes against the known-correct snapshot.
    // Both backends must agree on overlay storage size and byte aliasing, so any
    // divergence or regression on EITHER backend makes entry() return 0. Returns 1 iff
    // the overlay layout + member-read lowering are exactly as pinned.
    if (acc & 0xFFFFFFFF) != 0x158E96C4 { return 0; }
    return 1;
}
