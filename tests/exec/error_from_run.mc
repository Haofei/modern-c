// Runtime proof (G8) that postfix `?` CONVERTS the propagated error via the
// user-written `#[error_from]` conversion when the operand's error type (E1)
// differs from the enclosing function's error type (E2), on BOTH backends.
//
// The conversion is deliberately NON-identity on the raw values: LowErr.io (raw 0)
// maps to HighErr.fatal (raw 2), and LowErr.eof (raw 1) maps to HighErr.low (raw 0).
// A silent bit-reinterpretation of the error payload (the pre-G8 unsound behavior)
// would preserve the raw value (io->0, eof->1) and yield 1017; only a real call to
// `promote` produces the converted raws (io->2, eof->0) and yields 1207. The `ok`
// pass-through confirms the success path is unaffected by the inserted conversion.

enum LowErr { io, eof }              // io = 0, eof = 1
enum HighErr { low, other, fatal }   // low = 0, other = 1, fatal = 2

#[error_from]
fn promote(e: LowErr) -> HighErr {
    if e == LowErr.io { return HighErr.fatal; }  // 0 -> 2
    return HighErr.low;                          // eof(1) -> 0
}

fn make_io() -> Result<u32, LowErr> { return err(LowErr.io); }
fn make_eof() -> Result<u32, LowErr> { return err(LowErr.eof); }
fn make_ok() -> Result<u32, LowErr> { return ok(7); }

// The `?` operand is `Result<u32, LowErr>` but each caller returns
// `Result<u32, HighErr>`, so `?` must invoke `promote` on the error path.
fn use_io() -> Result<u32, HighErr> {
    let x: u32 = make_io()?;
    return ok(x);
}

fn use_eof() -> Result<u32, HighErr> {
    let x: u32 = make_eof()?;
    return ok(x);
}

fn use_ok() -> Result<u32, HighErr> {
    let x: u32 = make_ok()?;
    return ok(x);
}

// Extract the raw converted error, or the ok payload (+1000) so both edges show.
fn observe(r: Result<u32, HighErr>) -> u32 {
    switch r {
        ok(v) => { return 1000 + v; },  // ok(7) -> 1007
        err(e) => { return e.raw(); },
    }
}

export fn run() -> u32 {
    return observe(use_io()) * 100    // fatal.raw()=2 -> 200
        + observe(use_eof()) * 10     // low.raw()=0   -> 0
        + observe(use_ok());          // ok(7)         -> 1007
    // Converted: 200 + 0 + 1007 = 1207.
    // Reinterpreted (unsound, pre-G8): 0 + 10 + 1007 = 1017.
}
