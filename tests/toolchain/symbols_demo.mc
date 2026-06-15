// Fixture for `symbols-test`: exercises the `mcc symbols` index — a function with params and a
// local, a global read across functions, a type used as a parameter, and a cross-function call.
struct Point {
    x: u32,
    y: u32,
}

global origin: u32 = 0;

fn add(a: u32, b: u32) -> u32 {
    let sum: u32 = a + b;
    return sum + origin;
}

fn shift(p: Point, by: u32) -> u32 {
    return p.x + by;
}

fn caller() -> u32 {
    return add(1, 2);
}
