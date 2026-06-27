//! C backend layout assertion emission.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_reflect = @import("lower_c_reflect.zig");

const ReflectEnv = lower_c_reflect.ReflectEnv;

pub const AssertContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    structs: *const std.StringHashMap(ast.StructDecl),
    reflect_env: ReflectEnv,
};

/// Emit `_Static_assert(sizeof/offsetof == ...)` lines for every named struct
/// against MC's authoritative computed layout. When `fatal` is false, unresolved
/// layouts are skipped with comments so generated struct headers still compile.
pub fn appendLayoutAsserts(ctx: AssertContext, struct_names: []const []const u8, fatal: bool) !void {
    var reflect_env = ctx.reflect_env;
    for (struct_names) |name| {
        const struct_decl = ctx.structs.get(name) orelse return error.LayoutStructNotFound;
        const total = lower_c_reflect.comptimeStructSize(&reflect_env, struct_decl, 0) orelse {
            if (fatal) return error.LayoutUnresolved;
            try ctx.out.print(
                ctx.allocator,
                "/* layout cross-check skipped for {s}: MC does not compute its comptime size (tagged-union/nullable/overlay field); the struct definition above is authoritative. */\n",
                .{name},
            );
            continue;
        };
        // Resolve every field offset first, so a struct is either fully asserted
        // or fully skipped — never half-asserted.
        var offsets_ok = true;
        for (struct_decl.fields) |field| {
            if (lower_c_reflect.comptimeFieldOffset(&reflect_env, .{ .kind = .{ .name = struct_decl.name }, .span = struct_decl.name.span }, field.name.text, 0) == null) {
                offsets_ok = false;
                break;
            }
        }
        if (!offsets_ok) {
            if (fatal) return error.LayoutUnresolved;
            try ctx.out.print(
                ctx.allocator,
                "/* layout cross-check skipped for {s}: MC does not compute every field offset at comptime (tagged-union/nullable/overlay field); the struct definition above is authoritative. */\n",
                .{name},
            );
            continue;
        }
        try ctx.out.print(
            ctx.allocator,
            "_Static_assert(sizeof({s}) == {d}, \"MC<->C layout drift: sizeof({s})\");\n",
            .{ name, total, name },
        );
        for (struct_decl.fields) |field| {
            const offset = lower_c_reflect.comptimeFieldOffset(&reflect_env, .{ .kind = .{ .name = struct_decl.name }, .span = struct_decl.name.span }, field.name.text, 0).?;
            try ctx.out.print(
                ctx.allocator,
                "_Static_assert(offsetof({s}, {s}) == {d}, \"MC<->C layout drift: offsetof({s}, {s})\");\n",
                .{ name, field.name.text, offset, name, field.name.text },
            );
        }
    }
}
