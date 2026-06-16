// Differential-coverage fixture: overlay unions (byte-aliasing storage). Unlike MMIO offset
// structs these ARE host-runnable, so the entry constructs them, writes the scalar member, reads
// the aliased byte view + the scalar back, and folds them into a u32 — both backends must agree on
// the overlay layout (storage size + byte aliasing). `sizeof` of each overlay is also folded so the
// `comptimeStructLayout` size path is observed.
//
// NOTE ON READ FORM: a bare overlay-member read only lowers correctly in the *direct return
// position* of a same-typed accessor fn (cf. tests/c_emit/packed_overlay.mc::first_byte). Reading a
// member inside an `as` cast / initializer / arbitrary expression is NOT lowered by either backend
// today (it emits a raw `w.<member>` against the storage-only struct and fails to compile), and a
// non-byte array view (`[2]u16`, `[2]u32`) is not lowered at all — see the accompanying bug report.
// So this fixture reads strictly through accessor helpers and uses only the scalar + `[N]u8` views.

overlay union Word {
    u: u32,
    bytes: [4]u8,
}

overlay union WideWord {
    q: u64,
    octets: [8]u8,
}

fn word_u(w: Word) -> u32 { return w.u; }
fn word_byte(w: Word, i: usize) -> u8 { return w.bytes[i]; }

fn wide_q(w: WideWord) -> u64 { return w.q; }
fn wide_octet(w: WideWord, i: usize) -> u8 { return w.octets[i]; }

export fn entry() -> u32 {
    var acc: u64 = 0;

    var w: Word = uninit;
    w.u = 0x11223344;
    acc = (acc ^ (word_u(w) as u64));
    acc = (acc ^ ((word_byte(w, 0) as u64) << 8));
    acc = (acc ^ ((word_byte(w, 3) as u64) << 16));
    acc = (acc ^ ((sizeof(Word) as u64) << 4));

    var q: WideWord = uninit;
    q.q = 0x0102030405060708;
    acc = (acc ^ (wide_q(q) as u64));
    acc = (acc ^ ((wide_octet(q, 7) as u64) << 3));
    acc = (acc ^ ((sizeof(WideWord) as u64) << 5));

    return (acc & 0xFFFFFFFF) as u32;
}
