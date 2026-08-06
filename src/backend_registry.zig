const std = @import("std");

const backend = @import("backend.zig");
const lower_c = @import("lower_c.zig");
const lower_llvm = @import("lower_llvm.zig");

/// Registry of built-in backends. This is the composition root that is allowed
/// to know about concrete lowerer implementations; `backend.zig` remains the
/// interface and verified-program seam.
fn builtins() [2]backend.Backend {
    return .{ lower_c.mcBackend(), lower_llvm.mcBackend() };
}

/// All registered built-in backends.
pub fn all() [2]backend.Backend {
    return builtins();
}

/// Look up a backend by its CLI name ("c"/"llvm"); null if unknown.
pub fn byName(name: []const u8) ?backend.Backend {
    for (builtins()) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}
