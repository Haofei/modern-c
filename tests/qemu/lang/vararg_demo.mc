// Variadic-function demo for the riscv64 target: a C-ABI variadic MC function exercised
// end-to-end under QEMU. The `va.*` intrinsics (va.start / va.arg<T> / va.end) lower to the
// platform varargs ABI on BOTH backends (emit-c -> __builtin_va_*, emit-llvm -> llvm.va_start
// + the va_arg instruction). Called from the C runtime (vararg_runtime.c) the same way QuickJS
// will call our printf-family shims.
//
// `sum_args(count, ...)` reads `count` trailing i64 arguments off the varargs cursor and sums
// them — the integer-slot path that the formatter's %d/%lld handling depends on.

export fn sum_args(count: i32, ...) -> i64 {
    var ap: va_list = va.start();
    var total: i64 = 0;
    var i: i32 = 0;
    while i < count {
        unsafe {
            total = total + va.arg<i64>(&ap);
        }
        i = i + 1;
    }
    va.end(&ap);
    return total;
}
