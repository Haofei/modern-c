//! C MMIO struct declaration mechanics.
//!
//! Runtime MMIO reads and writes are executable-MIR operations rendered by
//! `mir_executable_c.zig`. This module retains only declaration layout output
//! for admitted MMIO structs.
//!
//! The layout comes from `mir.StructFact` and the signature-type table, not
//! from declaration syntax: the fact carries the field order, each field's
//! spelling and explicit offset, and the signature type from which the
//! register width is read. The caller used to materialize an AST `StructDecl`
//! out of exactly that fact and hand it over, so the syntax was a round-trip
//! through a representation this module never needed.

const std = @import("std");

const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");
const signature_type_mechanics = @import("signature_type_mechanics.zig");

const MmioField = lower_c_model.MmioField;
const mmioFieldWidthBytes = lower_c_type.mmioFieldWidthBytes;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;

pub const Context = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
};

pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;

pub const StructEmitContext = struct {
    context: Context,
    emit_ctx: *anyopaque,
    c_ident: CIdentFn,
    signature_types: mir.SignatureTypeTable,
};

/// The register shape of an MMIO field, read from its signature type.
/// `Reg<W>` is a plain register of width `W`; `RegBits<W, V>` is the same
/// storage viewed as `V`. This is the syntax-free counterpart of
/// `lower_c_shape.mmioFieldFromType`.
pub fn mmioFieldFromSignature(types: mir.SignatureTypeTable, id: mir.SignatureTypeId) ?MmioField {
    const shape = signature_type_mechanics.shape(types, id) catch return null;
    const generic = switch (shape) {
        .generic => |node| node,
        else => return null,
    };
    const is_reg = std.mem.eql(u8, generic.base, "Reg");
    const is_reg_bits = std.mem.eql(u8, generic.base, "RegBits");
    if (!is_reg and !is_reg_bits) return null;
    if (generic.args.len == 0) return null;
    const width = signatureTypeName(types, generic.args[0]) orelse "unknown";
    if (is_reg) return .{ .value_type = width, .width = width };
    const value_type = if (generic.args.len > 1)
        signatureTypeName(types, generic.args[1]) orelse width
    else
        width;
    return .{ .value_type = value_type, .width = width };
}

fn signatureTypeName(types: mir.SignatureTypeTable, id: mir.SignatureTypeId) ?[]const u8 {
    return switch (signature_type_mechanics.shape(types, id) catch return null) {
        .name => |name| name,
        else => null,
    };
}

pub fn emitStruct(ctx: StructEmitContext, name: []const u8, fields: []const mir.StructFieldFact) !void {
    try ctx.context.out.print(ctx.context.allocator, "typedef struct {s} {{\n", .{name});
    ctx.context.indent.* += 1;
    var running: u64 = 0;
    var pad_n: usize = 0;
    for (fields) |field| {
        try emitStructField(ctx, field, &running, &pad_n);
    }
    ctx.context.indent.* -= 1;
    try ctx.context.out.print(ctx.context.allocator, "}} {s};\n\n", .{name});
}

fn emitStructField(ctx: StructEmitContext, field: mir.StructFieldFact, running: *u64, pad_n: *usize) !void {
    const info = mmioFieldFromSignature(ctx.signature_types, field.type_id) orelse {
        try writeIndent(ctx.context);
        try ctx.context.out.print(ctx.context.allocator, "/* unsupported MMIO field: {s} */\n", .{field.spelling});
        return error.UnsupportedCEmission;
    };
    try emitFieldPadding(ctx.context, field, running, pad_n);
    try writeIndent(ctx.context);
    try ctx.context.out.print(ctx.context.allocator, "{s} volatile {s};\n", .{ primitiveCTypeName(info.width) orelse "void *", try ctx.c_ident(ctx.emit_ctx, field.spelling) });
    running.* += mmioFieldWidthBytes(info.width);
}

fn emitFieldPadding(ctx: Context, field: mir.StructFieldFact, running: *u64, pad_n: *usize) !void {
    const explicit = field.explicit_offset orelse return;
    const offset: u64 = @intCast(explicit);
    if (offset < running.*) return error.UnsupportedCEmission;
    if (offset == running.*) return;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "uint8_t _pad{d}[{d}];\n", .{ pad_n.*, offset - running.* });
    pad_n.* += 1;
    running.* = offset;
}

fn writeIndent(ctx: Context) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}
