const backend = @import("backend.zig");
const lower_c_shard = @import("test_shard_lower_c.zig");
const lower_llvm_shard = @import("test_shard_lower_llvm.zig");

test {
    _ = backend;
    _ = lower_c_shard;
    _ = lower_llvm_shard;
}
