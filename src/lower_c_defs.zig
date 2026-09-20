//! C backend typedef/aggregate declaration emitters.
//!
//! This module owns passive C declaration shapes. The main emitter still owns
//! type and declarator spelling through a narrow callback context, but that
//! context is typed on module-owned facts: a declaration is rendered from the
//! `EnumFact` / `TaggedUnionFact` / `StructFact` that carries it and from the
//! `SignatureTypeId` rows inside it, never from syntax materialized back out
//! of those facts.

const std = @import("std");

const lower_c_const = @import("lower_c_const.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");

const ArrayInfo = lower_c_model.ArrayInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const ResultInfo = lower_c_model.ResultInfo;
const OptInfo = lower_c_model.OptInfo;
const SliceInfo = lower_c_model.SliceInfo;

const cPayloadFieldName = lower_c_type.cPayloadFieldName;

pub const CTypeFn = *const fn (ctx: *anyopaque, id: mir.SignatureTypeId) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const FieldDeclaratorFn = *const fn (ctx: *anyopaque, id: mir.SignatureTypeId, name: []const u8) anyerror!void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    backend_names: *const std.StringHashMap([]const u8),
    emit_ctx: *anyopaque,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    field_declarator: FieldDeclaratorFn,
};

/// A nominal enum: a typedef for its checked representation plus one
/// enumerator per case. Every discriminant is already reduced to a sign and a
/// magnitude by the frontend, so nothing here re-reads a value expression.
pub fn emitEnumType(ctx: Context, name: []const u8, fact: mir.EnumFact) !void {
    const repr = try ctx.c_type(ctx.emit_ctx, fact.repr_type_id);
    try ctx.out.print(ctx.allocator, "typedef {s} {s};\n", .{ repr, name });
    try ctx.out.appendSlice(ctx.allocator, "enum {\n");
    ctx.indent.* += 1;
    for (fact.cases) |case| {
        try writeIndent(ctx);
        try ctx.out.print(ctx.allocator, "{s}_{s} = ", .{ name, case.spelling });
        if (case.negative) try ctx.out.appendSlice(ctx.allocator, "-");
        try lower_c_const.appendCIntValue(ctx.allocator, ctx.out, case.magnitude);
        try ctx.out.appendSlice(ctx.allocator, ",\n");
    }
    ctx.indent.* -= 1;
    try ctx.out.appendSlice(ctx.allocator, "};\n\n");
}

pub fn emitPackedBitsTypes(ctx: Context, packed_bits: *std.StringHashMap(PackedBitsInfo)) !void {
    var it = packed_bits.iterator();
    while (it.next()) |entry| {
        try ctx.out.print(ctx.allocator, "typedef {s} {s};\n\n", .{ entry.value_ptr.repr_c_type, entry.key_ptr.* });
    }
}

pub fn emitOverlayUnionTypes(ctx: Context, overlay_unions: *std.StringHashMap(OverlayUnionInfo)) !void {
    var it = overlay_unions.iterator();
    while (it.next()) |entry| try emitOverlayUnionType(ctx, entry.key_ptr.*, entry.value_ptr.*);
}

pub fn emitOverlayUnionType(ctx: Context, name: []const u8, info: OverlayUnionInfo) !void {
    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{name});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "alignas({d}) unsigned char storage[{d}];\n", .{ info.alignment, info.size });
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{name});
}

pub fn emitTaggedUnionType(ctx: Context, name: []const u8, cases: []const mir.TaggedUnionCaseFact) !void {
    try ctx.out.print(ctx.allocator, "typedef enum {s}Tag {{\n", .{name});
    ctx.indent.* += 1;
    for (cases, 0..) |case, i| {
        try writeIndent(ctx);
        try ctx.out.print(ctx.allocator, "{s}Tag_{s} = {d},\n", .{ name, case.spelling, i });
    }
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s}Tag;\n\n", .{name});

    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{name});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s}Tag tag;\n", .{name});

    if (taggedUnionHasPayload(cases)) {
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "union {\n");
        ctx.indent.* += 1;
        for (cases) |case| {
            const payload_type_id = case.payload_type_id orelse continue;
            try writeIndent(ctx);
            try ctx.out.print(ctx.allocator, "{s} {s};\n", .{
                try ctx.c_type(ctx.emit_ctx, payload_type_id),
                try cPayloadFieldName(ctx.scratch, case.spelling),
            });
        }
        ctx.indent.* -= 1;
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "} payload;\n");
    }

    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{name});
}

pub fn emitFunctionSignature(ctx: Context, name: []const u8, params: []const mir.CallableParameterEmissionFact, is_variadic: bool, ret: []const u8, param_types: []const []const u8, is_static: bool, with_asm_label: bool) !void {
    const cname = try ctx.c_ident(ctx.emit_ctx, name);
    try emitFunctionSignaturePrefix(ctx, ret, cname, is_static);
    try emitFunctionSignatureParams(ctx, params, is_variadic, param_types);
    try ctx.out.appendSlice(ctx.allocator, ")");
    try emitFunctionBackendAsmLabel(ctx, name, with_asm_label);
}

fn emitFunctionSignaturePrefix(ctx: Context, ret: []const u8, cname: []const u8, is_static: bool) !void {
    if (is_static) {
        try ctx.out.print(ctx.allocator, "MC_UNUSED static {s} {s}(", .{ ret, cname });
    } else {
        try ctx.out.print(ctx.allocator, "{s} {s}(", .{ ret, cname });
    }
}

fn emitFunctionSignatureParams(ctx: Context, params: []const mir.CallableParameterEmissionFact, is_variadic: bool, param_types: []const []const u8) !void {
    if (param_types.len != params.len) return error.InvalidFunctionSignature;
    if (params.len == 0) {
        try ctx.out.appendSlice(ctx.allocator, if (is_variadic) "" else "void");
    } else {
        for (params, 0..) |param, i| {
            if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
            try emitIgnoredLocalPrefix(ctx, param.spelling);
            try ctx.out.print(ctx.allocator, "{s} {s}", .{ param_types[i], try ctx.c_ident(ctx.emit_ctx, param.spelling) });
        }
    }
    if (is_variadic) {
        try ctx.out.appendSlice(ctx.allocator, ", ...");
    }
}

fn emitFunctionBackendAsmLabel(ctx: Context, name: []const u8, with_asm_label: bool) !void {
    if (!with_asm_label) return;
    const backend = ctx.backend_names.get(name) orelse return;
    try ctx.out.appendSlice(ctx.allocator, " __asm__(\"");
    try ctx.out.appendSlice(ctx.allocator, backend);
    try ctx.out.appendSlice(ctx.allocator, "\")");
}

pub fn emitStruct(ctx: Context, name: []const u8, is_c_union: bool, fields: []const mir.StructFieldFact) !void {
    // A `#[c_union]` lowers to a real C `union`: identical member declarations, but union
    // layout (all fields at offset 0, size = largest arm) and alias-safe `&u.field` access.
    const keyword: []const u8 = if (is_c_union) "union" else "struct";
    try ctx.out.print(ctx.allocator, "typedef {s} {s} {{\n", .{ keyword, name });
    ctx.indent.* += 1;
    for (fields) |field| {
        try writeIndent(ctx);
        try ctx.field_declarator(ctx.emit_ctx, field.type_id, field.spelling);
        try ctx.out.appendSlice(ctx.allocator, ";\n");
    }
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{name});
}

pub fn emitSliceTypes(ctx: Context, slice_types: *std.StringHashMap(SliceInfo)) !void {
    var it = slice_types.valueIterator();
    while (it.next()) |slice| {
        try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{slice.name});
        ctx.indent.* += 1;
        try writeIndent(ctx);
        try ctx.out.print(ctx.allocator, "{s} ptr;\n", .{slice.ptr_type});
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "uintptr_t len;\n");
        ctx.indent.* -= 1;
        try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{slice.name});
    }
}

pub fn emitResultType(ctx: Context, result: ResultInfo) !void {
    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{result.name});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "bool is_ok;\n");
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "union {\n");
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} ok;\n", .{result.ok_c_type});
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} err;\n", .{result.err_c_type});
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "} payload;\n");
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{result.name});
}

// A value optional `?T` — a tagged aggregate `{ bool present; T value; }`. `present`
// is the niche (false = absent / `null`); `value` holds the payload when present.
pub fn emitOptType(ctx: Context, opt: OptInfo) !void {
    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{opt.name});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "bool present;\n");
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} value;\n", .{opt.payload_c_type});
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{opt.name});
}

pub fn emitArrayType(ctx: Context, array: ArrayInfo) !void {
    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{array.name});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} elems[{d}];\n", .{ array.element_c_type, array.len });
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{array.name});
}

fn emitIgnoredLocalPrefix(ctx: Context, name: []const u8) !void {
    if (name.len > 0 and name[0] == '_') {
        try ctx.out.appendSlice(ctx.allocator, "MC_UNUSED ");
    }
}

fn writeIndent(ctx: Context) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

fn taggedUnionHasPayload(cases: []const mir.TaggedUnionCaseFact) bool {
    for (cases) |case| {
        if (case.payload_type_id != null) return true;
    }
    return false;
}
