//! C MMIO struct declaration mechanics.
//!
//! Runtime MMIO reads and writes are executable-MIR operations rendered by
//! `mir_executable_c.zig`. This module retains only declaration layout output
//! for admitted MMIO structs and does not inspect expression syntax.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");

const mmioFieldFromType = lower_c_shape.mmioFieldFromType;
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
};

pub fn emitStruct(ctx: StructEmitContext, struct_decl: ast_bridge.StructDecl) !void {
    try ctx.context.out.print(ctx.context.allocator, "typedef struct {s} {{\n", .{struct_decl.name.text});
    ctx.context.indent.* += 1;
    var running: u64 = 0;
    var pad_n: usize = 0;
    for (struct_decl.fields) |field| {
        try emitStructField(ctx, field, &running, &pad_n);
    }
    ctx.context.indent.* -= 1;
    try ctx.context.out.print(ctx.context.allocator, "}} {s};\n\n", .{struct_decl.name.text});
}

fn emitStructField(ctx: StructEmitContext, field: ast_bridge.Field, running: *u64, pad_n: *usize) !void {
    const info = mmioFieldFromType(field.ty) orelse {
        try writeIndent(ctx.context);
        try ctx.context.out.print(ctx.context.allocator, "/* unsupported MMIO field: {s} */\n", .{field.name.text});
        return error.UnsupportedCEmission;
    };
    try emitFieldPadding(ctx.context, field, running, pad_n);
    try writeIndent(ctx.context);
    try ctx.context.out.print(ctx.context.allocator, "{s} volatile {s};\n", .{ primitiveCTypeName(info.width) orelse "void *", try ctx.c_ident(ctx.emit_ctx, field.name.text) });
    running.* += mmioFieldWidthBytes(info.width);
}

fn emitFieldPadding(ctx: Context, field: ast_bridge.Field, running: *u64, pad_n: *usize) !void {
    const offset = field.offset orelse return;
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
