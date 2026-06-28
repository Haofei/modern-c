// examples/apps/wamr/compute.c — a no-WASI wasm32 guest for the first WAMR confined gate. Exports
// compute() with a small loop so the interpreter is exercised; the host calls it and prints the
// result over the syscall ABI. Built with `zig cc -target wasm32-freestanding` (no wasi-libc).
__attribute__((export_name("compute"))) int compute(void) {
    int s = 0;
    for (int i = 1; i <= 100; i++) s += i;   // 1+..+100 = 5050
    return s;
}
