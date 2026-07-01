//! C backend typedef/aggregate declaration emitters.
//!
//! This module owns passive C declaration shapes. The main emitter still owns
//! type spelling, declarator spelling, and expression-specific literal emission
//! through a narrow callback context.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");

const ArrayInfo = lower_c_model.ArrayInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const ResultInfo = lower_c_model.ResultInfo;
const OptInfo = lower_c_model.OptInfo;
const SliceInfo = lower_c_model.SliceInfo;

const cTraitIsObjectSafe = lower_c_shape.cTraitIsObjectSafe;
const cPayloadFieldName = lower_c_type.cPayloadFieldName;

pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const DeclaratorFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void;
pub const FieldDeclaratorFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void;
pub const EnumCaseValueFn = *const fn (ctx: *anyopaque, value: ast.Expr) anyerror!void;
pub const ResultPayloadCTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    backend_names: *const std.StringHashMap([]const u8),
    emit_ctx: *anyopaque,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    declarator: DeclaratorFn,
    field_declarator: FieldDeclaratorFn,
    enum_case_value: EnumCaseValueFn,
    result_payload_c_type: ResultPayloadCTypeFn,
};

pub fn emitEnums(ctx: Context, enums: *std.StringHashMap(ast.EnumDecl)) !void {
    var it = enums.valueIterator();
    while (it.next()) |enum_decl| try emitEnumType(ctx, enum_decl.*);
}

pub fn emitEnumType(ctx: Context, enum_decl: ast.EnumDecl) !void {
    const repr = if (enum_decl.repr) |repr_ty| try ctx.c_type(ctx.emit_ctx, repr_ty) else "intptr_t";
    try ctx.out.print(ctx.allocator, "typedef {s} {s};\n", .{ repr, enum_decl.name.text });
    try ctx.out.appendSlice(ctx.allocator, "enum {\n");
    ctx.indent.* += 1;
    for (enum_decl.cases, 0..) |case, i| {
        try writeIndent(ctx);
        try ctx.out.print(ctx.allocator, "{s}_{s}", .{ enum_decl.name.text, case.name.text });
        if (case.value) |value| {
            try ctx.out.appendSlice(ctx.allocator, " = ");
            try ctx.enum_case_value(ctx.emit_ctx, value);
        } else {
            try ctx.out.print(ctx.allocator, " = {d}", .{i});
        }
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

pub fn emitTaggedUnionType(ctx: Context, union_decl: ast.UnionDecl) !void {
    try ctx.out.print(ctx.allocator, "typedef enum {s}Tag {{\n", .{union_decl.name.text});
    ctx.indent.* += 1;
    for (union_decl.cases, 0..) |case, i| {
        try writeIndent(ctx);
        try ctx.out.print(ctx.allocator, "{s}Tag_{s} = {d},\n", .{ union_decl.name.text, case.name.text, i });
    }
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s}Tag;\n\n", .{union_decl.name.text});

    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{union_decl.name.text});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s}Tag tag;\n", .{union_decl.name.text});

    if (taggedUnionHasPayload(union_decl)) {
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "union {\n");
        ctx.indent.* += 1;
        for (union_decl.cases) |case| {
            const payload_ty = case.ty orelse continue;
            try writeIndent(ctx);
            try ctx.out.print(ctx.allocator, "{s} {s};\n", .{
                try ctx.c_type(ctx.emit_ctx, payload_ty),
                try cPayloadFieldName(ctx.scratch, case.name.text),
            });
        }
        ctx.indent.* -= 1;
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "} payload;\n");
    }

    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{union_decl.name.text});
}

pub fn emitAggregateForwardDeclarations(
    ctx: Context,
    module: ast.Module,
    structs: *std.StringHashMap(ast.StructDecl),
    tagged_unions: *std.StringHashMap(ast.UnionDecl),
    array_types: *std.StringHashMap(ArrayInfo),
    result_types: *std.StringHashMap(ResultInfo),
) !void {
    var emitted = false;
    for (module.decls) |decl| {
        var keyword: []const u8 = "struct";
        const name = switch (decl.kind) {
            .struct_decl => |struct_decl| blk: {
                if (!structs.contains(struct_decl.name.text)) continue;
                // A `#[c_union]` is a real C `union`; its forward tag must match its
                // definition tag (`typedef union U U;`), not the default `struct`.
                if (struct_decl.is_c_union) keyword = "union";
                break :blk struct_decl.name.text;
            },
            .union_decl => |union_decl| if (tagged_unions.contains(union_decl.name.text)) union_decl.name.text else continue,
            else => continue,
        };
        try ctx.out.print(ctx.allocator, "typedef {s} {s} {s};\n", .{ keyword, name, name });
        emitted = true;
    }
    {
        var it = array_types.valueIterator();
        while (it.next()) |array| {
            try ctx.out.print(ctx.allocator, "typedef struct {s} {s};\n", .{ array.name, array.name });
            emitted = true;
        }
    }
    {
        var it = result_types.valueIterator();
        while (it.next()) |result| {
            try ctx.out.print(ctx.allocator, "typedef struct {s} {s};\n", .{ result.name, result.name });
            emitted = true;
        }
    }
    if (emitted) try ctx.out.appendSlice(ctx.allocator, "\n");
}

pub fn emitFunctionSignature(ctx: Context, fn_decl: ast.FnDecl, is_static: bool, with_asm_label: bool) !void {
    const ret = if (fn_decl.return_type) |ret_ty| try ctx.c_type(ctx.emit_ctx, ret_ty) else "void";
    const cname = try ctx.c_ident(ctx.emit_ctx, fn_decl.name.text);
    try emitFunctionSignaturePrefix(ctx, ret, cname, is_static);
    try emitFunctionSignatureParams(ctx, fn_decl);
    try ctx.out.appendSlice(ctx.allocator, ")");
    try emitFunctionBackendAsmLabel(ctx, fn_decl, with_asm_label);
}

fn emitFunctionSignaturePrefix(ctx: Context, ret: []const u8, cname: []const u8, is_static: bool) !void {
    if (is_static) {
        try ctx.out.print(ctx.allocator, "MC_UNUSED static {s} {s}(", .{ ret, cname });
    } else {
        try ctx.out.print(ctx.allocator, "{s} {s}(", .{ ret, cname });
    }
}

fn emitFunctionSignatureParams(ctx: Context, fn_decl: ast.FnDecl) !void {
    if (fn_decl.params.len == 0) {
        try ctx.out.appendSlice(ctx.allocator, if (fn_decl.is_variadic) "" else "void");
    } else {
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
            try emitParamDecl(ctx, param.ty, param.name.text);
        }
    }
    if (fn_decl.is_variadic) {
        try ctx.out.appendSlice(ctx.allocator, ", ...");
    }
}

fn emitFunctionBackendAsmLabel(ctx: Context, fn_decl: ast.FnDecl, with_asm_label: bool) !void {
    if (!with_asm_label) return;
    const backend = ctx.backend_names.get(fn_decl.name.text) orelse return;
    try ctx.out.appendSlice(ctx.allocator, " __asm__(\"");
    try ctx.out.appendSlice(ctx.allocator, backend);
    try ctx.out.appendSlice(ctx.allocator, "\")");
}

pub fn emitParamDecl(ctx: Context, ty: ast.TypeExpr, name: []const u8) !void {
    try emitIgnoredLocalPrefix(ctx, name);
    try ctx.declarator(ctx.emit_ctx, ty, name);
}

pub fn emitStruct(ctx: Context, struct_decl: ast.StructDecl) !void {
    // A `#[c_union]` lowers to a real C `union`: identical member declarations, but union
    // layout (all fields at offset 0, size = largest arm) and alias-safe `&u.field` access.
    const keyword: []const u8 = if (struct_decl.is_c_union) "union" else "struct";
    try ctx.out.print(ctx.allocator, "typedef {s} {s} {{\n", .{ keyword, struct_decl.name.text });
    ctx.indent.* += 1;
    for (struct_decl.fields) |field| {
        try writeIndent(ctx);
        try ctx.field_declarator(ctx.emit_ctx, field.ty, field.name.text);
        try ctx.out.appendSlice(ctx.allocator, ";\n");
    }
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{struct_decl.name.text});
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
    try ctx.out.print(ctx.allocator, "{s} ok;\n", .{try ctx.result_payload_c_type(ctx.emit_ctx, result.ok_ty)});
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} err;\n", .{try ctx.result_payload_c_type(ctx.emit_ctx, result.err_ty)});
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
    try ctx.out.print(ctx.allocator, "{s} value;\n", .{try ctx.c_type(ctx.emit_ctx, opt.payload_ty)});
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{opt.name});
}

pub fn emitArrayType(ctx: Context, array: ArrayInfo) !void {
    try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{array.name});
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} elems[{s}];\n", .{ array.element_c_type, array.len });
    ctx.indent.* -= 1;
    try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{array.name});
}

pub fn emitFnPtrTypes(ctx: Context, fn_ptr_types: *std.StringHashMap(ast.TypeExpr)) !void {
    var it = fn_ptr_types.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.kind.fn_pointer;
        try ctx.out.appendSlice(ctx.allocator, "typedef ");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, node.ret.*));
        try ctx.out.print(ctx.allocator, " (*{s})(", .{entry.key_ptr.*});
        if (node.params.len == 0) {
            try ctx.out.appendSlice(ctx.allocator, "void");
        } else {
            for (node.params, 0..) |param, i| {
                if (i > 0) try ctx.out.appendSlice(ctx.allocator, ", ");
                try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, param));
            }
        }
        try ctx.out.appendSlice(ctx.allocator, ");\n\n");
    }
}

pub fn emitClosureTypes(ctx: Context, closure_types: *std.StringHashMap(ast.TypeExpr)) !void {
    var it = closure_types.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.kind.closure_type;
        try ctx.out.appendSlice(ctx.allocator, "typedef struct { ");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, node.ret.*));
        try ctx.out.appendSlice(ctx.allocator, " (*code)(void *");
        for (node.params) |param| {
            try ctx.out.appendSlice(ctx.allocator, ", ");
            try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, param));
        }
        try ctx.out.print(ctx.allocator, "); void *env; }} {s};\n\n", .{entry.key_ptr.*});
    }
}

pub fn emitDynTraitTypes(ctx: Context, trait_decls: *std.StringHashMap(ast.TraitDecl)) !void {
    var it = trait_decls.iterator();
    while (it.next()) |entry| {
        const trait = entry.value_ptr.*;
        if (!cTraitIsObjectSafe(trait)) continue;
        try ctx.out.print(ctx.allocator, "typedef struct {{ ", .{});
        for (trait.methods) |method| {
            try appendVtableSlotType(ctx, trait, method);
            try ctx.out.appendSlice(ctx.allocator, "; ");
        }
        try ctx.out.print(ctx.allocator, "}} VT_{s};\n", .{trait.name.text});
        try ctx.out.print(ctx.allocator, "typedef struct {{ void *data; VT_{s} const *vtable; }} mc_dyn_{s};\n\n", .{ trait.name.text, trait.name.text });
    }
}

fn appendVtableSlotType(ctx: Context, trait: ast.TraitDecl, method: ast.TraitMethodSig) !void {
    const ret_ty: ast.TypeExpr = method.return_type orelse ast.TypeExpr{ .span = trait.name.span, .kind = .{ .name = .{ .text = "void", .span = trait.name.span } } };
    try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, ret_ty));
    try ctx.out.appendSlice(ctx.allocator, " (*");
    try ctx.out.appendSlice(ctx.allocator, method.name.text);
    try ctx.out.appendSlice(ctx.allocator, ")(void *");
    for (method.params[1..]) |param| {
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, param.ty));
    }
    try ctx.out.appendSlice(ctx.allocator, ")");
}

fn emitIgnoredLocalPrefix(ctx: Context, name: []const u8) !void {
    if (name.len > 0 and name[0] == '_') {
        try ctx.out.appendSlice(ctx.allocator, "MC_UNUSED ");
    }
}

fn writeIndent(ctx: Context) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

fn taggedUnionHasPayload(union_decl: ast.UnionDecl) bool {
    for (union_decl.cases) |case| {
        if (case.ty != null) return true;
    }
    return false;
}
