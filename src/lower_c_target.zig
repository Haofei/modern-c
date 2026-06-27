//! C backend target and operation classifiers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_atomic = @import("lower_c_atomic.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");

const AtomicAccess = lower_c_model.AtomicAccess;
const DmaOperation = lower_c_model.DmaOperation;
const GlobalAccess = lower_c_model.GlobalAccess;
const GlobalInfo = lower_c_model.GlobalInfo;
const atomicOrderCConstant = lower_c_atomic.atomicOrderCConstant;
const atomicOrderingArg = lower_c_atomic.atomicOrderingArg;
const globalInfoFromType = lower_c_shape.globalInfoFromType;
const isAtomicIntegerPayload = lower_c_atomic.isAtomicIntegerPayload;
const isAtomicLoadOrdering = lower_c_atomic.isAtomicLoadOrdering;
const isAtomicStoreOrdering = lower_c_atomic.isAtomicStoreOrdering;
const calleeIdentName = ast_query.calleeIdentName;
const isIdentNamed = ast_query.isIdentNamed;
const memberExpr = ast_query.memberExpr;
const isSatPreservingBinary = ast_query.isSatPreservingBinary;
const isWrapPreservingBinary = lower_c_op.isWrapPreservingBinary;
const widthBits = lower_c_op.widthBits;

pub fn atomicAccess(callee: ast.Expr, args: []const ast.Expr, ctx: anytype) ?AtomicAccess {
    const member = memberExpr(callee) orelse return null;
    const object = calleeIdentName(member.base.*) orelse return null;
    const payload = ctx.local_atomic_payloads.get(object) orelse return null;
    if (std.mem.eql(u8, member.name.text, "load")) {
        const ordering = atomicOrderingArg(args, 0);
        if (!isAtomicLoadOrdering(ordering)) return null;
        return .{ .op = "load", .object = object, .payload_type = payload, .ordering = ordering };
    }
    if (std.mem.eql(u8, member.name.text, "store")) {
        const ordering = atomicOrderingArg(args, 1);
        if (!isAtomicStoreOrdering(ordering)) return null;
        return .{ .op = "store", .object = object, .payload_type = payload, .ordering = ordering };
    }
    if (std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
        if (!isAtomicIntegerPayload(payload)) return null;
        const ordering = atomicOrderingArg(args, 1);
        if (atomicOrderCConstant(ordering) == null) return null;
        return .{ .op = member.name.text, .object = object, .payload_type = payload, .ordering = ordering };
    }
    return null;
}

pub fn dmaOperation(callee: ast.Expr, args: []const ast.Expr, ctx: anytype) ?DmaOperation {
    const member = memberExpr(callee) orelse return null;
    if (isIdentNamed(member.base.*, "cache")) {
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return null;
        if (args.len != 1) return null;
        const object = calleeIdentName(args[0]) orelse return null;
        const payload = ctx.local_dma_payloads.get(object) orelse return null;
        const mode = ctx.local_dma_modes.get(object) orelse return null;
        if (!std.mem.eql(u8, mode, "noncoherent")) return null;
        return .{ .kind = member.name.text, .object = object, .payload = payload, .mode = mode };
    }
    const object = calleeIdentName(member.base.*) orelse return null;
    const payload = ctx.local_dma_payloads.get(object) orelse return null;
    const mode = ctx.local_dma_modes.get(object) orelse return null;
    if (std.mem.eql(u8, member.name.text, "dma_addr")) {
        if (args.len != 0) return null;
        return .{ .kind = "dma_addr", .object = object, .payload = payload, .mode = mode };
    }
    if (std.mem.eql(u8, member.name.text, "as_slice")) {
        if (args.len != 0) return null;
        return .{ .kind = "as_slice", .object = object, .payload = payload, .mode = mode };
    }
    return null;
}

pub fn dmaAddrHandoffObject(value: ast.Expr, ctx: anytype) ?[]const u8 {
    return switch (value.kind) {
        .grouped => |inner| dmaAddrHandoffObject(inner.*, ctx),
        .call => |call| blk: {
            const op = dmaOperation(call.callee.*, call.args, ctx) orelse break :blk null;
            if (!std.mem.eql(u8, op.kind, "dma_addr")) break :blk null;
            break :blk op.object;
        },
        else => null,
    };
}

pub fn exprType(expr: ast.Expr, ctx: anytype) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ctx.local_types.get(ident.text),
        .grouped => |inner| exprType(inner.*, ctx),
        .unary => |node| exprType(node.expr.*, ctx),
        else => null,
    };
}

pub fn arithmeticDomainForBinary(node: anytype, ctx: anytype) ?[]const u8 {
    if (isWrapPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, "wrap") and exprHasArithmeticDomain(node.right.*, ctx, "wrap")) return "wrap";
    if (isSatPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, "sat") and exprHasArithmeticDomain(node.right.*, ctx, "sat")) return "sat";
    return null;
}

pub fn exprHasArithmeticDomain(expr: ast.Expr, ctx: anytype, domain: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.local_domains.get(ident.text)) |found| std.mem.eql(u8, found, domain) else false,
        .grouped => |inner| exprHasArithmeticDomain(inner.*, ctx, domain),
        .binary => |node| if (std.mem.eql(u8, domain, "wrap"))
            isWrapPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, domain) and exprHasArithmeticDomain(node.right.*, ctx, domain)
        else if (std.mem.eql(u8, domain, "sat"))
            isSatPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, domain) and exprHasArithmeticDomain(node.right.*, ctx, domain)
        else
            false,
        else => false,
    };
}

pub fn iterableElementCTypeForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(lower_c_model.LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.iterable_element_c_type else null,
        .grouped => |inner| iterableElementCTypeForExpr(inner.*, locals),
        else => null,
    };
}

pub fn ordinaryGlobalTarget(allocator: std.mem.Allocator, target: ast.Expr, ctx: anytype, globals: std.StringHashMap(GlobalInfo), structs: std.StringHashMap(ast.StructDecl)) ?GlobalAccess {
    return switch (target.kind) {
        .ident => |ident| if (!ctx.locals.contains(ident.text))
            if (globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null
        else
            null,
        .index => |index| ordinaryGlobalArrayTarget(allocator, index, ctx, globals),
        .member => |member| ordinaryGlobalMemberTarget(allocator, member, ctx, globals, structs),
        .grouped => |inner| ordinaryGlobalTarget(allocator, inner.*, ctx, globals, structs),
        else => null,
    };
}

pub fn ordinaryGlobalArrayTarget(allocator: std.mem.Allocator, index: anytype, ctx: anytype, globals: std.StringHashMap(GlobalInfo)) ?GlobalAccess {
    const base_name = calleeIdentName(index.base.*) orelse return null;
    if (ctx.locals.contains(base_name)) return null;
    const global = globals.get(base_name) orelse return null;
    const element_info = global.array_element_info orelse return null;
    return .{
        .name = std.fmt.allocPrint(allocator, "{s}[]", .{base_name}) catch return null,
        .info = .{
            .type_name = element_info.race_type_name,
            .c_type = element_info.c_type,
            .race_type_name = element_info.race_type_name,
            .race_c_type = element_info.race_c_type,
            .width_bits = widthBits(element_info.race_type_name),
            .pointer_like = false,
            .source_ty = element_info.source_ty,
        },
        .owned_name = true,
    };
}

pub fn ordinaryGlobalMemberTarget(allocator: std.mem.Allocator, member: anytype, ctx: anytype, globals: std.StringHashMap(GlobalInfo), structs: std.StringHashMap(ast.StructDecl)) ?GlobalAccess {
    const base_name = calleeIdentName(member.base.*) orelse return null;
    if (ctx.locals.contains(base_name)) return null;
    const global = globals.get(base_name) orelse return null;
    const struct_decl = structs.get(global.type_name) orelse return null;
    for (struct_decl.fields) |field| {
        if (!std.mem.eql(u8, field.name.text, member.name.text)) continue;
        return .{
            .name = std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, member.name.text }) catch return null,
            .info = globalInfoFromType(field.ty),
            .owned_name = true,
        };
    }
    return null;
}

pub fn localOrdinaryTarget(target: ast.Expr, ctx: anytype) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| if (ctx.locals.contains(ident.text)) ident.text else null,
        .grouped => |inner| localOrdinaryTarget(inner.*, ctx),
        else => null,
    };
}

pub fn assignmentRangeTargetName(target: ast.Expr) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| ident.text,
        .member => |member| member.name.text,
        .grouped => |inner| assignmentRangeTargetName(inner.*),
        else => null,
    };
}

pub fn isFixtureLocalAccess(fn_name: []const u8, object: []const u8) bool {
    return std.mem.eql(u8, fn_name, "local_non_racing_access") and std.mem.eql(u8, object, "local");
}
