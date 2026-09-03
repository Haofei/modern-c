//! Compiler unit-test aggregation root.
//!
//! Keep this separate from `main.zig` so the CLI entrypoint does not own the
//! repository's test module inventory. The build registry runs the four roots
//! below independently for `test-unit`; this composition root preserves
//! identical coverage for direct `zig test src/test_root.zig` use.

const core = @import("test_root_core.zig");
const mir = @import("test_root_mir.zig");
const lower_c = @import("test_shard_lower_c.zig");
const lower_llvm = @import("test_shard_lower_llvm.zig");

test {
    _ = core;
    _ = mir;
    _ = lower_c;
    _ = lower_llvm;
}
