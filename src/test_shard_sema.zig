const eval_tests = @import("eval_tests.zig");
const monomorphize_tests = @import("monomorphize_tests.zig");
const sema = @import("sema.zig");
const sema_tests = @import("sema_tests.zig");

test {
    _ = eval_tests;
    _ = monomorphize_tests;
    _ = sema;
    _ = sema_tests;
}
