// Scalar type layout — the size and alignment of MC's fixed-width builtin types.
//
// The same name→{size, alignment} table was copied into sema.zig, mir.zig, lower_c.zig, and
// lower_llvm.zig (the checker sizes types, the MIR optimizer reasons about them, both backends
// emit them). One definition keeps every pass agreeing on how wide each type is — a divergence
// here would mean the front-end and a backend disagree on a struct's layout.

const std = @import("std");
const ast = @import("ast.zig");
const numeric = @import("numeric.zig");
const alignForward = numeric.alignForward;

/// Size and (natural) alignment in bytes. For the scalar builtins these are equal.
pub const ScalarLayout = struct { size: u32, alignment: u32 };

/// The comptime-computed layout of a struct: its total size and alignment, plus the byte
/// offset of a particular field when one was requested. Both backends compute this identically.
pub const ComptimeStructLayout = struct {
    size: i128,
    alignment: i128,
    field_offset: ?i128,
};

pub const ComptimeOptionalLayout = struct {
    size: i128,
    alignment: i128,
    payload_offset: i128,
};

/// Layout of the tagged value-optional representation `{ bool present; T value; }`.
/// Pointer and fat-pointer niche optionals bypass this helper and retain their child layout.
pub fn comptimeTaggedOptionalLayout(payload_size: i128, payload_alignment: i128) ?ComptimeOptionalLayout {
    if (payload_size < 0 or payload_alignment <= 0) return null;
    const payload_offset = alignForward(@as(i128, 1), payload_alignment) orelse return null;
    const end = comptimeLayoutAdd(payload_offset, payload_size) orelse return null;
    return .{
        .size = alignForward(end, payload_alignment) orelse return null,
        .alignment = payload_alignment,
        .payload_offset = payload_offset,
    };
}

/// Size of a fixed array in bytes, or null when the comptime layout would overflow the
/// i128 layout domain. Reflection callers use null as "unknown" so hostile array lengths
/// fail closed instead of trapping the compiler.
pub fn comptimeArraySize(len: anytype, elem_size: i128) ?i128 {
    if (elem_size < 0) return null;
    const len_i128 = std.math.cast(i128, len) orelse return null;
    if (len_i128 < 0) return null;
    return std.math.mul(i128, len_i128, elem_size) catch null;
}

/// Add two non-negative comptime layout quantities, or null on overflow/invalid input.
pub fn comptimeLayoutAdd(lhs: i128, rhs: i128) ?i128 {
    if (lhs < 0 or rhs < 0) return null;
    return std.math.add(i128, lhs, rhs) catch null;
}

/// Convert a byte offset to a bit offset, or null on overflow/invalid input.
pub fn comptimeBitOffset(byte_offset: i128) ?i128 {
    return comptimeArraySize(@as(i128, 8), byte_offset);
}

/// Compute the comptime layout of `struct_decl`, returning total size/alignment and (when
/// `wanted_field` is non-null) the byte offset of that field. This is the single shared
/// implementation used by BOTH backends (`lower_c.zig` and `lower_llvm.zig`) so they can never
/// silently diverge on how a struct is laid out.
///
/// The per-field size and alignment are resolved through caller-supplied callbacks, because each
/// backend consults its own emitter state (type aliases, enums, packed-bit reprs, Result payloads,
/// …) to size a field type. `ctx` is that emitter; `sizeOf`/`alignOf` are the emitter methods.
/// `depth` is threaded through unchanged for the existing recursion-guard.
///
/// Explicit field offsets (`field.offset`, from `@offset(N)` field attributes) must be
/// monotonically non-decreasing: an explicit offset that lands *before* the current running
/// offset would overlap a previous field and yields a bogus layout, so it is rejected (returns
/// null). Both backends now share this guard — previously only the C backend had it while the
/// LLVM backend accepted overlapping offsets, a latent divergence.
pub fn comptimeStructLayout(
    comptime Ctx: type,
    ctx: Ctx,
    struct_decl: ast.StructDecl,
    wanted_field: ?[]const u8,
    depth: usize,
    comptime sizeOf: fn (Ctx, ast.TypeExpr, usize) ?i128,
    comptime alignOf: fn (Ctx, ast.TypeExpr, usize) ?i128,
) ?ComptimeStructLayout {
    if (depth > 32) return null;
    // A `#[c_union]` lays out like a real C union: every field starts at offset 0, the
    // total size is the largest field (rounded up to the max alignment), and the align is
    // the max field alignment. The active arm is chosen at runtime; only one is live.
    if (struct_decl.is_c_union) {
        var max_size: i128 = 0;
        var union_align: i128 = 1;
        var union_found: ?i128 = null;
        for (struct_decl.fields) |field| {
            const size = sizeOf(ctx, field.ty, depth + 1) orelse return null;
            const alignment = alignOf(ctx, field.ty, depth + 1) orelse return null;
            if (size < 0) return null;
            if (alignment <= 0) return null;
            if (alignment > union_align) union_align = alignment;
            if (size > max_size) max_size = size;
            if (wanted_field) |wanted| {
                if (std.mem.eql(u8, field.name.text, wanted)) union_found = 0;
            }
        }
        return .{
            .size = alignForward(max_size, union_align) orelse return null,
            .alignment = union_align,
            .field_offset = union_found,
        };
    }
    var offset: i128 = 0;
    var max_align: i128 = 1;
    var found: ?i128 = null;
    for (struct_decl.fields) |field| {
        const size = sizeOf(ctx, field.ty, depth + 1) orelse return null;
        const alignment = alignOf(ctx, field.ty, depth + 1) orelse return null;
        if (size < 0) return null;
        if (alignment <= 0) return null;
        if (alignment > max_align) max_align = alignment;
        if (field.offset) |explicit| {
            const explicit_offset: i128 = @intCast(explicit);
            if (explicit_offset < offset) return null;
            offset = explicit_offset;
        } else {
            offset = alignForward(offset, alignment) orelse return null;
        }
        if (wanted_field) |wanted| {
            if (std.mem.eql(u8, field.name.text, wanted)) found = offset;
        }
        offset = comptimeLayoutAdd(offset, size) orelse return null;
    }
    return .{
        .size = alignForward(offset, max_align) orelse return null,
        .alignment = max_align,
        .field_offset = found,
    };
}

/// The layout of a scalar builtin type named `name`, or null if `name` is not one. Opaque
/// address classes (`PAddr`/`VAddr`/`DmaAddr`) lower to pointer-width integers.
pub fn scalarLayout(name: []const u8) ?ScalarLayout {
    const table = [_]struct { n: []const u8, s: u32 }{
        .{ .n = "u8", .s = 1 },      .{ .n = "i8", .s = 1 },    .{ .n = "bool", .s = 1 },
        .{ .n = "u16", .s = 2 },     .{ .n = "i16", .s = 2 },   .{ .n = "u32", .s = 4 },
        .{ .n = "i32", .s = 4 },     .{ .n = "f32", .s = 4 },   .{ .n = "u64", .s = 8 },
        .{ .n = "i64", .s = 8 },     .{ .n = "f64", .s = 8 },   .{ .n = "usize", .s = 8 },
        .{ .n = "isize", .s = 8 },   .{ .n = "PAddr", .s = 8 }, .{ .n = "VAddr", .s = 8 },
        .{ .n = "DmaAddr", .s = 8 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.n)) return .{ .size = entry.s, .alignment = entry.s };
    }
    return null;
}

const test_zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

fn testIdent(name: []const u8) ast.Ident {
    return .{ .text = name, .span = test_zero_span };
}

fn testType(name: []const u8) ast.TypeExpr {
    return .{ .span = test_zero_span, .kind = .{ .name = testIdent(name) } };
}

fn testSizeOf(_: void, ty: ast.TypeExpr, _: usize) ?i128 {
    const name = switch (ty.kind) {
        .name => |n| n.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "huge")) return std.math.maxInt(i128);
    if (std.mem.eql(u8, name, "neg")) return -1;
    return 1;
}

fn testAlignOf(_: void, _: ast.TypeExpr, _: usize) ?i128 {
    return 1;
}

test "comptimeArraySize and comptimeBitOffset fail closed on i128 overflow" {
    try std.testing.expectEqual(@as(?i128, 32), comptimeArraySize(@as(usize, 4), 8));
    try std.testing.expectEqual(@as(?i128, null), comptimeArraySize(@as(usize, 2), std.math.maxInt(i128)));
    try std.testing.expectEqual(@as(?i128, null), comptimeArraySize(@as(i128, -1), 8));
    try std.testing.expectEqual(@as(?i128, 16), comptimeBitOffset(2));
    try std.testing.expectEqual(@as(?i128, null), comptimeBitOffset(std.math.maxInt(i128)));
}

test "comptimeTaggedOptionalLayout matches bool plus aligned payload" {
    try std.testing.expectEqual(
        ComptimeOptionalLayout{ .size = 8, .alignment = 4, .payload_offset = 4 },
        comptimeTaggedOptionalLayout(4, 4).?,
    );
    try std.testing.expectEqual(
        ComptimeOptionalLayout{ .size = 16, .alignment = 8, .payload_offset = 8 },
        comptimeTaggedOptionalLayout(8, 8).?,
    );
    try std.testing.expectEqual(@as(?ComptimeOptionalLayout, null), comptimeTaggedOptionalLayout(-1, 1));
}

test "comptimeStructLayout fails closed on field size overflow" {
    var fields = [_]ast.Field{
        .{ .name = testIdent("a"), .ty = testType("huge") },
        .{ .name = testIdent("b"), .ty = testType("u8") },
    };
    const decl = ast.StructDecl{ .name = testIdent("S"), .abi = null, .fields = &fields };
    try std.testing.expectEqual(@as(?ComptimeStructLayout, null), comptimeStructLayout(void, {}, decl, null, 0, testSizeOf, testAlignOf));
}

test "comptimeStructLayout rejects negative field sizes" {
    var fields = [_]ast.Field{
        .{ .name = testIdent("a"), .ty = testType("neg") },
    };
    const decl = ast.StructDecl{ .name = testIdent("S"), .abi = null, .fields = &fields };
    try std.testing.expectEqual(@as(?ComptimeStructLayout, null), comptimeStructLayout(void, {}, decl, null, 0, testSizeOf, testAlignOf));
}
