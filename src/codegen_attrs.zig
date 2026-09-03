//! Syntax-free codegen attribute facts.
//!
//! Declaration collection may derive these facts from source attributes, but
//! C/LLVM codegen should consume this normalized shape rather than importing
//! syntax attribute helpers.

const std = @import("std");
const ast_bridge = @import("ast_bridge.zig");
const mir = @import("mir_model.zig");

pub const FunctionRenderAttrs = mir.FunctionRenderAttrs;

pub const GlobalSignatureFacts = struct {
    name: ast_bridge.Ident,
    value_ty: mir.ValueType,
    /// Module-owned recursive declaration shape; never source syntax.
    type_id: mir.SignatureTypeId = .invalid,
    is_const: bool,
    exported: bool,
    is_extern: bool,
};

pub const GlobalInitFacts = struct {
    body_id: mir.BodyId = .invalid,
    init: ?ast_bridge.Expr,
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
