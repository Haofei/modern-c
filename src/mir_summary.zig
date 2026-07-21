const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const mir_model = @import("mir_model.zig");

pub const FunctionSummary = struct {
    no_lang_trap: bool,
    irq_context: bool,
    return_ty: mir_model.ValueType,
    return_type_expr: ?ast.TypeExpr,
    params: []const ast.Param,
};

pub const EnumSummary = struct {
    is_open: bool,
    cases: []const ast.EnumCase,
    repr: ?ast.TypeExpr,
};

pub const StructSummary = struct {
    fields: []const ast.Field,
    is_c_union: bool = false,
};

pub const UnionSummary = struct {
    cases: []const ast.UnionCase,
};

pub const PackedBitsSummary = struct {
    repr: ast.TypeExpr,
    fields: []const ast.Field,
};

pub const ReflectEnv = struct {
    enums: *const std.StringHashMap(EnumSummary),
    structs: *const std.StringHashMap(StructSummary),
    unions: *const std.StringHashMap(UnionSummary),
    packed_bits: *const std.StringHashMap(PackedBitsSummary),
    aliases: *const std.StringHashMap(ast.TypeExpr),
};

pub const ConstGlobalMap = std.StringHashMap(eval.ComptimeValue);
