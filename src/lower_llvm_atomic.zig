//! LLVM backend — atomic-ordering & fence helpers.
//!
//! Pure (no `LlvmEmitter` state) helpers that recognize atomic-init calls,
//! extract memory-ordering arguments, map MC orderings to their LLVM textual
//! orderings per access context, and resolve fence orderings. Extracted from
//! `lower_llvm.zig` verbatim as part of the Phase-2c structural split;
//! behavior is unchanged. The spine references these through re-export aliases
//! so call sites read unchanged. Mirrors `lower_c_atomic.zig` to keep the two
//! backends parallel.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

const isIdentNamed = ast_query.isIdentNamed;

pub const AtomicOrderContext = enum {
    load,
    store,
    rmw,
};

pub fn atomicOrderingArg(args: []const ast.Expr, index: usize) ?[]const u8 {
    if (index >= args.len) return null;
    return atomicOrderingExpr(args[index]);
}

pub fn atomicOrderingExpr(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| atomicOrderingExpr(inner.*),
        else => null,
    };
}

pub fn orderingArg(expr: ast.Expr) ?[]const u8 {
    return atomicOrderingExpr(expr);
}

pub fn atomicLlvmOrdering(ordering: []const u8, context: AtomicOrderContext) ?[]const u8 {
    if (std.mem.eql(u8, ordering, "relaxed")) return "monotonic";
    return switch (context) {
        .load => {
            if (std.mem.eql(u8, ordering, "acquire")) return "acquire";
            if (std.mem.eql(u8, ordering, "seq_cst")) return "seq_cst";
            return null;
        },
        .store => {
            if (std.mem.eql(u8, ordering, "release")) return "release";
            if (std.mem.eql(u8, ordering, "seq_cst")) return "seq_cst";
            return null;
        },
        .rmw => {
            if (std.mem.eql(u8, ordering, "acquire")) return "acquire";
            if (std.mem.eql(u8, ordering, "release")) return "release";
            if (std.mem.eql(u8, ordering, "acq_rel")) return "acq_rel";
            if (std.mem.eql(u8, ordering, "seq_cst")) return "seq_cst";
            return null;
        },
    };
}

pub fn fenceOrderingForCall(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| blk: {
            if (!isIdentNamed(member.base.*, "fence")) break :blk null;
            if (std.mem.eql(u8, member.name.text, "full")) break :blk "seq_cst";
            if (std.mem.eql(u8, member.name.text, "release")) break :blk "release";
            if (std.mem.eql(u8, member.name.text, "acquire")) break :blk "acquire";
            break :blk null;
        },
        .grouped => |inner| fenceOrderingForCall(inner.*),
        else => null,
    };
}
