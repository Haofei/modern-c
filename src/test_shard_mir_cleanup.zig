const backend_cleanup = @import("backend_cleanup.zig");
const mir = @import("mir.zig");
const mir_tests = @import("mir_tests.zig");
const sema_move = @import("sema_move.zig");

test {
    _ = backend_cleanup;
    _ = mir;
    _ = mir_tests;
    _ = sema_move;
}
