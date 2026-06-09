// An architecture-neutral MC computation, compiled for a second architecture (aarch64)
// to prove the language/codegen + the arch-isolated kernel layout port beyond riscv64.
export fn arch_compute(x: u32) -> u32 {
    var acc: u32 = 0;
    var i: u32 = 0;
    while i < x {
        acc = acc + i;
        i = i + 1;
    }
    return acc * 2 + 1; // sum(0..x-1)*2 + 1
}
