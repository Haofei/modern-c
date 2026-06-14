// Regression (sanitize, C-backend): a narrow `wrap<u16>` multiply was emitted as a plain C `*`,
// where u16 operands integer-promote to signed `int`; 60000*60000 overflows `int` (UB). Fixed in
// lower_c.zig by computing narrow wrap + - * in `unsigned int` (the .unsigned_infix plan).
export fn harness() -> u64 {
    var a: wrap<u16> = 60000;
    var b: wrap<u16> = 60000;
    var c: wrap<u16> = (a * b);
    return (c as u64);
}
