//! Syntax-free codegen attribute facts.
//!
//! Declaration collection may derive these facts from source attributes, but
//! C/LLVM codegen should consume this normalized shape rather than importing
//! syntax attribute helpers.

const std = @import("std");
const ast_bridge = @import("ast_bridge.zig");
const codegen_signature = @import("codegen_signature.zig");
const mir = @import("mir_model.zig");

pub const FunctionParamFact = codegen_signature.FunctionParamFact;

pub const FunctionSignatureFacts = struct {
    name: ast_bridge.Ident,
    params: []const FunctionParamFact,
    /// Canonical semantic return type produced by the checked MIR builder.
    return_ty: mir.ValueType,
    /// Module-owned recursive source type shape. Kept in parallel with the
    /// transitional AST payload until signature renderers cut over.
    return_type_id: mir.SignatureTypeId = .invalid,
    /// Compatibility payload for backend helpers that have not yet moved to
    /// `return_ty`. Function signature emission must not use this field.
    transitional_ret_type: ?ast_bridge.TypeExpr,
    exported: bool,
    is_extern: bool,
    is_const: bool,
    is_variadic: bool,
    c_abi: bool,
    error_from: bool,
    backend_name: ?[]const u8,

    pub fn transitionalReturnType(self: FunctionSignatureFacts) ?ast_bridge.TypeExpr {
        return self.transitional_ret_type;
    }
};

pub const FunctionBodyFacts = struct {
    has_definition: bool,
};

pub const GlobalSignatureFacts = struct {
    name: ast_bridge.Ident,
    value_ty: mir.ValueType,
    ty: ?ast_bridge.TypeExpr,
    is_const: bool,
    exported: bool,
    is_extern: bool,
};

pub const GlobalInitFacts = struct {
    body_id: mir.BodyId = .invalid,
    init: ?ast_bridge.Expr,
};

pub const FunctionRenderAttrs = struct {
    naked: bool = false,
    weak: bool = false,
    noinline_attr: bool = false,
    section: ?[]const u8 = null,
    effective_align: ?u32 = null,
};

pub fn emitCFunctionRenderAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: FunctionRenderAttrs) !void {
    try emitCLinkageFunctionAttrs(allocator, out, attrs);
    try emitCLayoutFunctionAttrs(allocator, out, attrs);
    try emitCInliningFunctionAttrs(allocator, out, attrs);
}

fn emitCLinkageFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: FunctionRenderAttrs) !void {
    if (attrs.weak) try out.appendSlice(allocator, "MC_WEAK ");
    if (attrs.section) |sec| {
        try out.appendSlice(allocator, "__attribute__((section(\"");
        try out.appendSlice(allocator, sec);
        try out.appendSlice(allocator, "\"))) ");
    }
}

fn emitCLayoutFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: FunctionRenderAttrs) !void {
    if (attrs.effective_align) |al| {
        var buf: [32]u8 = undefined;
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "__attribute__((aligned({d}))) ", .{al}) catch unreachable);
    }
}

fn emitCInliningFunctionAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), attrs: FunctionRenderAttrs) !void {
    if (attrs.noinline_attr) try out.appendSlice(allocator, "__attribute__((noinline)) ");
    if (attrs.naked) try out.appendSlice(allocator, "__attribute__((naked)) ");
}
