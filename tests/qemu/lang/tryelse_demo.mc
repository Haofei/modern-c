// `EXPR? else MAPPED`: propagate a remapped error instead of the original, so a layer can
// translate a subsystem's error type into its own without a hand-written switch.
enum LowErr { Disk, Net }
enum HighErr { Unused, Failed }

fn low(good: bool) -> Result<u32, LowErr> {
    if good {
        return ok(42);
    }
    return err(.Disk);
}

fn high(good: bool) -> Result<u32, HighErr> {
    let v: u32 = low(good)? else .Failed; // LowErr -> HighErr.Failed on error
    return ok(v * 2);
}

export fn tryelse_run() -> u32 {
    var pass: u32 = 1;
    switch high(true) {
        ok(v) => { if v != 84 { pass = 0; } } // ok path: 42*2
        err(e) => { pass = 0; }
    }
    switch high(false) {
        ok(v) => { pass = 0; }       // must be err: low() failed, remapped to HighErr.Failed
        err(e) => {}
    }
    return pass;
}
