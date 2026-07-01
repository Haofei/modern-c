// raw.load<T>/raw.store<T> generalize past scalars: an aggregate (struct) T
// lowers to a whole-object typed load/store `(*(T *)(addr))`, mirroring the
// `raw.ptr<T>(addr)` + deref path. Scalar T keeps its `mc_raw_load_*` helper
// lowering unchanged. Both are exercised here so the c-test gate compiles them.
struct Tok {
    kind: u32,
    a: usize,
    b: usize,
}

// Aggregate load: reads the whole struct value from the raw address.
fn load_tok(addr: usize) -> Tok {
    unsafe {
        return raw.load<Tok>(phys(addr));
    }
}

// Aggregate store: writes the whole struct value to the raw address.
fn store_tok(addr: usize, t: Tok) -> void {
    unsafe {
        raw.store<Tok>(phys(addr), t);
    }
}

// Aggregate round-trip through one raw cell.
fn copy_tok(src: usize, dst: usize) -> void {
    unsafe {
        let v: Tok = raw.load<Tok>(phys(src));
        raw.store<Tok>(phys(dst), v);
    }
}

// Scalar path stays exactly as before (mc_raw_load_/mc_raw_store_ helpers).
fn copy_word(src: usize, dst: usize) -> void {
    unsafe {
        let w: u32 = raw.load<u32>(phys(src));
        raw.store<u32>(phys(dst), w);
    }
}
