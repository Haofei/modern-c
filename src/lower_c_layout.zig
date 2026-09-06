//! C backend layout assertion emission.

const std = @import("std");

const mir = @import("mir.zig");

pub const AssertContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mir_module: *const mir.Module,
};

/// Emit `_Static_assert(sizeof/offsetof == ...)` lines for every named struct
/// against MIR's admitted storage facts. When `fatal` is false, unresolved
/// layouts are skipped with comments so generated struct headers still compile.
pub fn appendLayoutAsserts(ctx: AssertContext, struct_names: []const []const u8, fatal: bool) !void {
    for (struct_names) |name| {
        const struct_fact = structFactByName(ctx.mir_module, name) orelse return error.LayoutStructNotFound;
        const total = struct_fact.storage_size orelse {
            if (fatal) return error.LayoutUnresolved;
            try ctx.out.print(
                ctx.allocator,
                "/* layout cross-check skipped for {s}: MIR has no admitted storage size; the struct definition above is authoritative. */\n",
                .{name},
            );
            continue;
        };
        // Resolve every field offset first, so a struct is either fully asserted
        // or fully skipped — never half-asserted.
        var offsets_ok = true;
        for (struct_fact.fields) |field| {
            if (field.offset == null) {
                offsets_ok = false;
                break;
            }
        }
        if (!offsets_ok) {
            if (fatal) return error.LayoutUnresolved;
            try ctx.out.print(
                ctx.allocator,
                "/* layout cross-check skipped for {s}: MIR has no admitted offset for every field; the struct definition above is authoritative. */\n",
                .{name},
            );
            continue;
        }
        try ctx.out.print(
            ctx.allocator,
            "_Static_assert(sizeof({s}) == {d}, \"MC<->C layout drift: sizeof({s})\");\n",
            .{ name, total, name },
        );
        for (struct_fact.fields) |field| {
            const offset = field.offset.?;
            try ctx.out.print(
                ctx.allocator,
                "_Static_assert(offsetof({s}, {s}) == {d}, \"MC<->C layout drift: offsetof({s}, {s})\");\n",
                .{ name, field.spelling, offset, name, field.spelling },
            );
        }
    }
}

fn structFactByName(module: *const mir.Module, name: []const u8) ?mir.StructFact {
    for (module.structs) |fact| {
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len) continue;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id)) continue;
        if (std.mem.eql(u8, identity.spelling, name)) return fact;
    }
    return null;
}
