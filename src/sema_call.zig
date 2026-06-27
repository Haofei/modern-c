const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const sema_model = @import("sema_model.zig");
const sema_type = @import("sema_type.zig");

const Context = sema_model.Context;
const TypeClass = sema_model.TypeClass;

const byteViewCallKind = ast_query.byteViewCallKind;
const reduceCallKind = ast_query.reduceCallKind;
const simpleNameType = ast_query.simpleNameType;

const classifyType = sema_type.classifyType;
const classifyTypeCtx = sema_type.classifyTypeCtx;
const isArithmeticDomain = sema_type.isArithmeticDomain;
const isCheckedInt = sema_type.isCheckedInt;
const resolveAliasType = sema_type.resolveAliasType;

// Resolves a member base that names a scalar integer or arithmetic-domain type
// (directly or through a type alias), for static operations like `TcpSeq.before(a, b)`
// or `u8.try_from(x)`. Returns null when the base is a value binding or does not
// name such a type.
pub fn staticTypeBaseClass(base: ast.Expr, ctx: Context) ?TypeClass {
    const ident = switch (base.kind) {
        .ident => |id| id,
        .grouped => |inner| return staticTypeBaseClass(inner.*, ctx),
        else => return null,
    };
    if (ctx.scope) |scope| {
        if (scope.get(ident.text) != null) return null;
    }
    const resolved = resolveAliasType(simpleNameType(ident.text, ident.span), ctx);
    const class = classifyType(resolved);
    if (isCheckedInt(class) or isArithmeticDomain(class)) return class;
    return null;
}

pub fn isTypeStaticMember(member: anytype, ctx: Context) bool {
    return staticTypeBaseClass(member.base.*, ctx) != null;
}

pub fn reduceCallReturnClass(call: anytype, ctx: Context) ?TypeClass {
    const kind = reduceCallKind(call.callee.*) orelse return null;
    return switch (kind) {
        .sum_checked => .result,
        .sum_left, .sum_fast => if (call.type_args.len == 1) classifyTypeCtx(call.type_args[0], ctx) else .unknown,
    };
}

pub fn byteViewCallReturnClass(call: anytype) ?TypeClass {
    const kind = byteViewCallKind(call.callee.*) orelse return null;
    return switch (kind) {
        .as_bytes => .slice,
        .bytes_equal => .bool,
    };
}

pub fn typeStaticCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return typeStaticCallReturnClass(inner.*, ctx),
        else => return null,
    };
    const class = staticTypeBaseClass(member.base.*, ctx) orelse return null;
    const op = member.name.text;
    if (std.mem.eql(u8, op, "try_from")) return .result;
    if (std.mem.eql(u8, op, "from_mod")) return if (class == .wrap) .wrap else null;
    if (std.mem.eql(u8, op, "from") or
        std.mem.eql(u8, op, "trap_from") or
        std.mem.eql(u8, op, "wrap_from") or
        std.mem.eql(u8, op, "sat_from")) return class;
    if (class == .serial) {
        if (std.mem.eql(u8, op, "before") or std.mem.eql(u8, op, "after")) return .bool;
        if (std.mem.eql(u8, op, "distance")) return .wrap;
        if (std.mem.eql(u8, op, "compare")) return .result;
    } else if (class == .counter) {
        if (std.mem.eql(u8, op, "delta_mod")) return .wrap;
        if (std.mem.eql(u8, op, "elapsed_assume_within")) return .duration;
        if (std.mem.eql(u8, op, "elapsed_bounded")) return .result;
    }
    return null;
}
