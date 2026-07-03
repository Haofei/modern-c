// SPEC: section=32.5
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_EFFECT_MISMATCH

trait Sink {
    fn flush(self: *Self) -> u32;
}

struct Disk {
    n: u32,
}

impl Sink for Disk {
    #[may_sleep]
    fn flush(self: *Disk) -> u32 { // EXPECT_ERROR: E_TRAIT_EFFECT_MISMATCH
        return self.n;
    }
}
