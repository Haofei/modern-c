// Aggregate raw memory access uses an explicit raw pointer. raw.load/raw.store
// are scalar-only because their contract is one volatile, instrumented access.
struct Tok {
    kind: u32,
    a: usize,
    b: usize,
}

fn load_tok(addr: usize) -> Tok {
    unsafe {
        let pointer: *mut Tok = raw.ptr<Tok>(phys(addr));
        return pointer.*;
    }
}

fn store_tok(addr: usize, t: Tok) -> void {
    unsafe {
        let pointer: *mut Tok = raw.ptr<Tok>(phys(addr));
        pointer.* = t;
    }
}

fn copy_tok(src: usize, dst: usize) -> void {
    unsafe {
        let source: *mut Tok = raw.ptr<Tok>(phys(src));
        let target: *mut Tok = raw.ptr<Tok>(phys(dst));
        target.* = source.*;
    }
}

// Scalar path stays exactly as before (mc_raw_load_/mc_raw_store_ helpers).
fn copy_word(src: usize, dst: usize) -> void {
    unsafe {
        let w: u32 = raw.load<u32>(phys(src));
        raw.store<u32>(phys(dst), w);
    }
}
