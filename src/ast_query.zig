// Small pure AST-shape queries shared across the checker, MIR builder, and C backend.
//
// These recognize specific syntactic forms (an identifier by name, an `mmio.map<T>(...)`
// intrinsic call and its payload type) and were previously copied into `sema.zig`, `mir.zig`,
// and `lower_c.zig`. The copies had drifted — only the MIR copy of `isIdentNamed` looked through
// grouping parens — so a parenthesized intrinsic was recognized in one pass but not another.
// One definition keeps the three passes agreeing on what a given form *is*.

const std = @import("std");

const ast = @import("ast.zig");

/// True when `expr` is (transparently through grouping parens) the identifier `name`.
/// Grouping is semantically invisible — `(x)` is `x` — so `(mmio).map(...)` must read the
/// same as `mmio.map(...)`.
pub fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| isIdentNamed(inner.*, name),
        else => false,
    };
}

/// True when `callee` names the `mmio.map` intrinsic (`mmio.map<T>(...)`), through grouping.
pub fn isMmioMapCallName(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "map") and isIdentNamed(member.base.*, "mmio"),
        .grouped => |inner| isMmioMapCallName(inner.*),
        else => false,
    };
}

/// For an `mmio.map<T>(...)` call, the payload type `MmioPtr<T>`; null for any other call. Takes
/// `call: anytype` so it accepts every pass's call node shape (all expose `callee` and
/// `type_args`).
pub fn mmioMapCallPayloadType(call: anytype) ?ast.TypeExpr {
    if (!isMmioMapCallName(call.callee.*) or call.type_args.len != 1) return null;
    return .{
        .span = call.type_args[0].span,
        .kind = .{ .generic = .{
            .base = .{ .text = "MmioPtr", .span = call.type_args[0].span },
            .args = call.type_args[0..1],
        } },
    };
}
