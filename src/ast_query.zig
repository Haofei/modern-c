// Pure AST-shape queries shared across the checker, MIR builder, and C backend.
//
// These recognize syntactic forms over the AST — an identifier by name, an `mmio.map<T>(...)`
// intrinsic call and its payload, a fully-narrowed `Result` local, a layout/arithmetic type
// generic — returning a bool, a name, or an `ast` node. They were previously copied into
// `sema.zig`, `mir.zig`, and `lower_c.zig`; some copies had drifted (only the MIR copy of
// `isIdentNamed` looked through grouping parens), so a parenthesized form was recognized in one
// pass but not another. One definition keeps the passes agreeing on what a given form *is*.
//
// Only forms that are byte-identical across the passes live here; deliberately per-pass queries
// (e.g. `structTypeName`, whose sema copy alone sees through a pointer) stay in their file.

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

// ── Expression / pattern queries ──────────────────────────────────────────────────────────

/// True when `expr` is the identifier `name`, through grouping parens. (A second spelling of
/// `isIdentNamed`, kept distinct only because callers reference both names.)
pub fn exprIsIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| exprIsIdentNamed(inner.*, name),
        else => false,
    };
}

/// The `bool` value of a boolean-literal expression (through grouping), or null.
pub fn boolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped => |inner| boolLiteralValue(inner.*),
        else => null,
    };
}

/// True when `expr` is the `---` uninitialized literal, through grouping.
pub fn isUninitLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped => |inner| isUninitLiteral(inner.*),
        else => false,
    };
}

/// True when `name` is a `Result` narrowing tag (`ok` / `err`).
pub fn isResultNarrowingTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "err");
}

/// True when the local declaration binds `name` (one of its `names`).
pub fn localDeclaresName(local: ast.LocalDecl, name: []const u8) bool {
    for (local.names) |ident| {
        if (std.mem.eql(u8, ident.text, name)) return true;
    }
    return false;
}

/// True when `if let ok(x) = name { … } else { … }` fully narrows the `Result` local `name`
/// (a tag-binding `ok`/`err` pattern over `name`, with an `else`).
pub fn resultIfLetHandlesLocal(name: []const u8, node: ast.IfLet) bool {
    if (node.else_block == null or !exprIsIdentNamed(node.value, name)) return false;
    return switch (node.pattern.kind) {
        .tag_bind => |tag_bind| isResultNarrowingTag(tag_bind.tag.text),
        else => false,
    };
}

/// True when a `switch` over `name` exhaustively handles the `Result` local — either a
/// wildcard arm, or both an `ok` and an `err` arm.
pub fn resultSwitchHandlesLocal(name: []const u8, node: ast.Switch) bool {
    if (!exprIsIdentNamed(node.subject, name)) return false;
    var has_wildcard = false;
    var has_ok = false;
    var has_err = false;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .wildcard => has_wildcard = true,
                .tag => |tag| {
                    if (std.mem.eql(u8, tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag.text, "err")) has_err = true;
                },
                .tag_bind => |tag_bind| {
                    if (std.mem.eql(u8, tag_bind.tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag_bind.tag.text, "err")) has_err = true;
                },
                .literal, .bind => {},
            }
        }
    }
    return has_wildcard or (has_ok and has_err);
}

/// The contract name of an attribute (`#[unsafe_contract(name)]`), or `"unknown"`.
pub fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named, .backend_name, .origin => "unknown",
    };
}

// ── Type-shape queries ────────────────────────────────────────────────────────────────────

/// The leading type name of a (possibly `qualified`) named type, or null.
pub fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

/// True for a raw many-pointer type `[*]T` (through a qualifier).
pub fn isRawManyPointerType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .raw_many_pointer => true,
        .qualified => |node| isRawManyPointerType(node.child.*),
        else => false,
    };
}

/// True for the pointer-like layout generics (`MmioPtr`, `UserPtr`).
pub fn isPointerLikeGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "MmioPtr") or std.mem.eql(u8, name, "UserPtr");
}

/// True for the arithmetic-layout generics that wrap a scalar (`wrap`, `sat`, `serial`,
/// `counter`, `Duration`).
pub fn isArithmeticLayoutGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration");
}

/// True for a saturating-arithmetic type `sat<T>` (through a qualifier).
pub fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

/// True for a wrapping-arithmetic type `wrap<T>` (through a qualifier).
pub fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

/// The pointee type name of an `MmioPtr<T>`, or null for any other type.
pub fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

/// True for the binary operators whose result a saturating type preserves (`+`, `-`, `*`).
pub fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}
