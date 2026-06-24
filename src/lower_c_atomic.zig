//! C backend — atomic ordering + memory-fence helper classifiers.
//!
//! Pure (no `CEmitter` state) helpers that classify atomic memory orderings,
//! map them to the C `__ATOMIC_*` constants, validate atomic payload types, and
//! resolve `fence.*` calls to their runtime barrier helpers. Extracted verbatim
//! from `lower_c.zig` as part of the Phase-2a structural split; behavior is
//! unchanged. Call sites in the spine reference these through re-export aliases.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

const isIdentNamed = ast_query.isIdentNamed;

pub fn orderingArg(args: []ast.Expr) []const u8 {
    for (args) |arg| {
        if (arg.kind == .enum_literal) return arg.kind.enum_literal.text;
    }
    return "none";
}

pub fn atomicOrderingArg(args: []const ast.Expr, index: usize) []const u8 {
    if (index >= args.len) return "none";
    return switch (args[index].kind) {
        .enum_literal => |literal| literal.text,
        else => "none",
    };
}

pub fn asmHasMemoryClobber(asm_stmt: ast.AsmStmt) bool {
    if (asm_stmt.clobbers.len == 0) return true;
    for (asm_stmt.clobbers) |clobber| {
        if (std.mem.indexOf(u8, clobber, "memory") != null) return true;
    }
    return false;
}

pub fn atomicOrderCConstant(ordering: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ordering, "relaxed")) return "__ATOMIC_RELAXED";
    if (std.mem.eql(u8, ordering, "acquire")) return "__ATOMIC_ACQUIRE";
    if (std.mem.eql(u8, ordering, "release")) return "__ATOMIC_RELEASE";
    if (std.mem.eql(u8, ordering, "acq_rel")) return "__ATOMIC_ACQ_REL";
    if (std.mem.eql(u8, ordering, "seq_cst")) return "__ATOMIC_SEQ_CST";
    return null;
}

pub fn atomicOrderSynchronizes(ordering: []const u8) bool {
    return !std.mem.eql(u8, ordering, "relaxed") and atomicOrderCConstant(ordering) != null;
}

pub fn isAtomicLoadOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "acquire") or
        std.mem.eql(u8, ordering, "seq_cst");
}

pub fn isAtomicStoreOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "release") or
        std.mem.eql(u8, ordering, "seq_cst");
}

pub fn isAtomicIntegerPayload(name: []const u8) bool {
    return std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "i8") or
        std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "isize");
}

pub fn fenceHelperForCall(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |node| blk: {
            if (!isIdentNamed(node.base.*, "fence")) break :blk null;
            if (std.mem.eql(u8, node.name.text, "full")) break :blk "mc_barrier_full";
            if (std.mem.eql(u8, node.name.text, "release")) break :blk "mc_barrier_release_before";
            if (std.mem.eql(u8, node.name.text, "acquire")) break :blk "mc_barrier_acquire_after";
            break :blk null;
        },
        .grouped => |inner| fenceHelperForCall(inner.*),
        else => null,
    };
}
