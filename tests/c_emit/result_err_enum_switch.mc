// Switching directly on an enum bound from a Result `err(e)` payload must lower (the C backend
// previously inferred no enum type for the binding and failed with UnsupportedCEmission, while
// the LLVM backend lowered it fine — a backend divergence the differential tester surfaces).
enum IoError { Timeout, Closed, Reset }

extern fn read_once() -> Result<u32, IoError>;

export fn classify_read() -> u32 {
    switch read_once() {
        ok(v) => { return v; }
        err(e) => {
            switch e {
                .Timeout => { return 1; }
                .Closed => { return 2; }
                _ => { return 3; }
            }
        }
    }
}

// Also exercise an if-let-style nested match path on the err binding.
export fn read_or_zero() -> u32 {
    switch read_once() {
        ok(v) => { return v; }
        err(e) => {
            switch e {
                .Reset => { return 0; }
                _ => { return 9; }
            }
        }
    }
}
