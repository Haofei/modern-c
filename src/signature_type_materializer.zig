//! One-way transitional materialization of a syntax-free signature shape.
//!
//! The declaration ingress owns no `ast.TypeExpr` for type aliases. Legacy
//! aggregate/global/comptime mechanics still accept an AST-shaped type, so
//! legacy consumers materialize one here from the single module
//! `SignatureTypeTable`.

const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir_model.zig");
const signature_type_mechanics = @import("signature_type_mechanics.zig");

pub const Error = error{ InvalidSignatureType, UnsupportedSignatureType } || std.mem.Allocator.Error;

pub fn typeExpr(
    allocator: std.mem.Allocator,
    table: mir.SignatureTypeTable,
    id: mir.SignatureTypeId,
    span: ast.Span,
) Error!ast.TypeExpr {
    const shape = try signature_type_mechanics.shape(table, id);
    const child = struct {
        fn make(
            alloc: std.mem.Allocator,
            types: mir.SignatureTypeTable,
            child_id: mir.SignatureTypeId,
            source_span: ast.Span,
        ) Error!*ast.TypeExpr {
            const value = try alloc.create(ast.TypeExpr);
            value.* = try typeExpr(alloc, types, child_id, source_span);
            return value;
        }
    }.make;
    return .{ .span = span, .kind = switch (shape) {
        .name => |name| .{ .name = .{ .text = name, .span = span } },
        .enum_literal => |name| .{ .enum_literal = .{ .text = name, .span = span } },
        .member => |node| .{ .member = .{
            .base = try child(allocator, table, node.base, span),
            .field = .{ .text = node.field, .span = span },
        } },
        .nullable => |node| .{ .nullable = try child(allocator, table, node, span) },
        .qualified => |node| .{ .qualified = .{
            .mutability = astMutability(node.mutability),
            .child = try child(allocator, table, node.child, span),
        } },
        .pointer => |node| .{ .pointer = .{
            .mutability = astMutability(node.mutability),
            .child = try child(allocator, table, node.child, span),
        } },
        .raw_many_pointer => |node| .{ .raw_many_pointer = .{
            .mutability = astMutability(node.mutability),
            .child = try child(allocator, table, node.child, span),
        } },
        .slice => |node| .{ .slice = .{
            .mutability = astMutability(node.mutability),
            .child = try child(allocator, table, node.child, span),
        } },
        .array => |node| blk: {
            const length = node.length orelse return error.UnsupportedSignatureType;
            const text = try std.fmt.allocPrint(allocator, "{d}", .{length});
            break :blk .{ .array = .{
                .len = .{ .span = span, .kind = .{ .int_literal = text } },
                .child = try child(allocator, table, node.child, span),
            } };
        },
        .generic => |node| blk: {
            const args = try allocator.alloc(ast.TypeExpr, node.args.len);
            for (node.args, 0..) |arg, index| args[index] = try typeExpr(allocator, table, arg, span);
            break :blk .{ .generic = .{ .base = .{ .text = node.base, .span = span }, .args = args } };
        },
        .fn_pointer => |node| blk: {
            const params = try allocator.alloc(ast.TypeExpr, node.params.len);
            for (node.params, 0..) |param, index| params[index] = try typeExpr(allocator, table, param, span);
            break :blk .{ .fn_pointer = .{
                .params = params,
                .ret = try child(allocator, table, node.ret, span),
            } };
        },
        .closure_type => |node| blk: {
            const params = try allocator.alloc(ast.TypeExpr, node.params.len);
            for (node.params, 0..) |param, index| params[index] = try typeExpr(allocator, table, param, span);
            break :blk .{ .closure_type = .{
                .params = params,
                .ret = try child(allocator, table, node.ret, span),
            } };
        },
        .dyn_trait => |node| .{ .dyn_trait = .{
            .mutability = astMutability(node.mutability),
            .trait_name = .{ .text = node.trait_name, .span = span },
        } },
    } };
}

fn astMutability(mutability: mir.TypeMutability) ast.Mutability {
    return switch (mutability) {
        .none => .none,
        .mut => .mut,
        .@"const" => .@"const",
    };
}
