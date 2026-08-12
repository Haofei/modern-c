//! Narrow expression-shape helpers.
//!
//! These helpers are syntax-only adapters used while backend lowering is still
//! migrating from AST-shaped input to MIR/verified facts.  Keeping this surface
//! smaller than `ast_query.zig` makes remaining syntax dependencies explicit
//! and easier to ratchet down.

const std = @import("std");

const ast = @import("ast.zig");

pub fn boolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped, .move_expr => |inner| boolLiteralValue(inner.*),
        else => null,
    };
}

pub fn nakedAsmStmt(body: ast.Block) ?ast.AsmStmt {
    if (body.items.len != 1) return null;
    return switch (body.items[0].kind) {
        .asm_stmt => |stmt| stmt,
        .unsafe_block => |inner| if (inner.items.len == 1) switch (inner.items[0].kind) {
            .asm_stmt => |stmt| stmt,
            else => null,
        } else null,
        else => null,
    };
}

pub fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .naked, .@"noinline", .weak, .named, .backend_name, .origin, .section, .@"align" => "unknown",
    };
}

pub fn isUninitLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped, .move_expr => |inner| isUninitLiteral(inner.*),
        else => false,
    };
}

pub fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped, .move_expr => |inner| isIdentNamed(inner.*, name),
        else => false,
    };
}

pub fn byteViewAddressTarget(expr: ast.Expr) ?ast.Expr {
    return switch (expr.kind) {
        .address_of => |target| target.*,
        .grouped, .move_expr => |inner| byteViewAddressTarget(inner.*),
        else => null,
    };
}

pub fn addressOfIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| addressOfIdentName(inner.*),
        .address_of => |inner| switch (inner.kind) {
            .grouped => addressOfIdentName(inner.*),
            .ident => |ident| ident.text,
            else => null,
        },
        else => null,
    };
}

pub fn calleeIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped, .move_expr => |inner| calleeIdentName(inner.*),
        else => null,
    };
}

pub fn atomicOrderingArg(args: []const ast.Expr, index: usize) ?[]const u8 {
    if (index >= args.len) return null;
    return atomicOrderingExpr(args[index]);
}

pub fn atomicOrderingExpr(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped, .move_expr => |inner| atomicOrderingExpr(inner.*),
        else => null,
    };
}

pub const CallExpr = struct {
    callee: *ast.Expr,
    type_args: []ast.TypeExpr,
    args: []ast.Expr,
};

pub fn callExpr(expr: ast.Expr) ?CallExpr {
    return switch (expr.kind) {
        .call => |node| .{ .callee = node.callee, .type_args = node.type_args, .args = node.args },
        .grouped, .move_expr => |inner| callExpr(inner.*),
        else => null,
    };
}

pub const DropPointerLocalReleaseCall = struct {
    fn_name: []const u8,
    local_name: []const u8,
    span: ast.Span,
};

pub fn dropPointerLocalReleaseCall(expr: ast.Expr) ?DropPointerLocalReleaseCall {
    const call = callExpr(expr) orelse return null;
    const fn_name = calleeIdentName(call.callee.*) orelse return null;
    if (call.type_args.len != 0 or call.args.len != 1) return null;
    const local_name = addressOfIdentName(call.args[0]) orelse return null;
    return .{ .fn_name = fn_name, .local_name = local_name, .span = expr.span };
}

pub const MemberExpr = struct { base: *ast.Expr, name: ast.Ident };

pub fn memberExpr(expr: ast.Expr) ?MemberExpr {
    return switch (expr.kind) {
        .member => |node| .{ .base = node.base, .name = node.name },
        .grouped, .move_expr => |inner| memberExpr(inner.*),
        else => null,
    };
}

pub const IndexExpr = struct { base: *ast.Expr, index: *ast.Expr };

pub fn indexExpr(expr: ast.Expr) ?IndexExpr {
    return switch (expr.kind) {
        .index => |node| .{ .base = node.base, .index = node.index },
        .grouped, .move_expr => |inner| indexExpr(inner.*),
        else => null,
    };
}

pub const MemberCallee = struct { base: *ast.Expr, name: ast.Ident };

pub fn memberCallee(expr: ast.Expr) ?MemberCallee {
    return switch (expr.kind) {
        .member => |node| .{ .base = node.base, .name = node.name },
        .grouped, .move_expr => |inner| memberCallee(inner.*),
        else => null,
    };
}

pub const QualifiedCallee = struct { owner: []const u8, member: ast.Ident };

pub fn qualifiedMemberCallee(expr: ast.Expr) ?QualifiedCallee {
    return switch (expr.kind) {
        .member => |node| switch (node.base.*.kind) {
            .ident => |base_ident| .{ .owner = base_ident.text, .member = node.name },
            else => null,
        },
        .grouped, .move_expr => |inner| qualifiedMemberCallee(inner.*),
        else => null,
    };
}

pub fn reflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped, .move_expr => |inner| reflectionFieldName(inner.*),
        else => null,
    };
}

pub fn taggedUnionCase(union_decl: ast.UnionDecl, name: []const u8) ?ast.UnionCase {
    for (union_decl.cases) |case| {
        if (std.mem.eql(u8, case.name.text, name)) return case;
    }
    return null;
}

pub fn dynCalleeMethodName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |m| m.name.text,
        .grouped, .move_expr => |inner| dynCalleeMethodName(inner.*),
        else => null,
    };
}

pub fn isRawLoadCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "load") and isIdentNamed(member.base.*, "raw"),
        .grouped, .move_expr => |inner| isRawLoadCall(inner.*),
        else => false,
    };
}

pub fn isRawPtrCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "ptr") and isIdentNamed(member.base.*, "raw"),
        .grouped, .move_expr => |inner| isRawPtrCall(inner.*),
        else => false,
    };
}

pub fn isRawStoreCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "store") and isIdentNamed(member.base.*, "raw"),
        .grouped, .move_expr => |inner| isRawStoreCall(inner.*),
        else => false,
    };
}

pub const ReduceCallKind = enum { sum_checked, sum_left, sum_fast };

pub fn reduceCallKind(callee: ast.Expr) ?ReduceCallKind {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped, .move_expr => |inner| return reduceCallKind(inner.*),
        else => return null,
    };
    if (!isIdentNamed(member.base.*, "reduce")) return null;
    if (std.mem.eql(u8, member.name.text, "sum_checked")) return .sum_checked;
    if (std.mem.eql(u8, member.name.text, "sum_left")) return .sum_left;
    if (std.mem.eql(u8, member.name.text, "sum_fast")) return .sum_fast;
    return null;
}

pub fn overlayMemberFromIndexBase(expr: ast.Expr) ?@TypeOf(expr.kind.member) {
    return switch (expr.kind) {
        .member => |member| member,
        .grouped, .move_expr => |inner| overlayMemberFromIndexBase(inner.*),
        else => null,
    };
}

pub const ReflectionValueCallKind = enum { size, repr, alignment, field_offset, bit_offset };

pub fn reflectionValueCallKind(callee: ast.Expr) ?ReflectionValueCallKind {
    const name = calleeIdentName(callee) orelse return null;
    if (std.mem.eql(u8, name, "size_of") or std.mem.eql(u8, name, "sizeof")) return .size;
    if (std.mem.eql(u8, name, "repr_of")) return .repr;
    if (std.mem.eql(u8, name, "alignof")) return .alignment;
    if (std.mem.eql(u8, name, "field_offset")) return .field_offset;
    if (std.mem.eql(u8, name, "bit_offset")) return .bit_offset;
    return null;
}

pub fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}
