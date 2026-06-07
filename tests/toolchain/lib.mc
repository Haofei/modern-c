// Toolchain smoke fixture: an exported function that `mcc-cc` compiles into a
// linkable object whose symbol the test then verifies.
export fn mc_add3(a: u32, b: u32, c: u32) -> u32 {
    return a + b + c;
}
