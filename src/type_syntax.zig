const std = @import("std");

const ast = @import("ast.zig");

pub const ViewKind = enum {
    pointer,
    raw_many_pointer,
    slice,
};

pub const ViewType = struct {
    kind: ViewKind,
    mutability: ast.Mutability,
    nullable: bool = false,
};

pub fn viewType(ty: ast.TypeExpr) ?ViewType {
    return switch (ty.kind) {
        .pointer => |node| .{ .kind = .pointer, .mutability = node.mutability },
        .raw_many_pointer => |node| .{ .kind = .raw_many_pointer, .mutability = node.mutability },
        .slice => |node| .{ .kind = .slice, .mutability = node.mutability },
        .nullable => |child| {
            var view = viewType(child.*) orelse return null;
            view.nullable = true;
            return view;
        },
        .qualified => |node| viewType(node.child.*),
        else => null,
    };
}

pub fn viewElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .nullable => |child| viewElementType(child.*),
        .qualified => |node| viewElementType(node.child.*),
        else => null,
    };
}

pub fn sameTypeSyntax(left: ast.TypeExpr, right: ast.TypeExpr) bool {
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .name => |left_name| std.mem.eql(u8, left_name.text, switch (right.kind) {
            .name => |right_name| right_name.text,
            else => unreachable,
        }),
        .enum_literal => |left_name| std.mem.eql(u8, left_name.text, switch (right.kind) {
            .enum_literal => |right_name| right_name.text,
            else => unreachable,
        }),
        .member => |left_node| blk: {
            const right_node = switch (right.kind) {
                .member => |node| node,
                else => unreachable,
            };
            break :blk sameTypeSyntax(left_node.base.*, right_node.base.*) and
                std.mem.eql(u8, left_node.field.text, right_node.field.text);
        },
        .nullable => |left_child| sameTypeSyntax(left_child.*, switch (right.kind) {
            .nullable => |right_child| right_child.*,
            else => unreachable,
        }),
        .qualified => |left_node| blk: {
            const right_node = switch (right.kind) {
                .qualified => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .raw_many_pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .raw_many_pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .slice => |left_node| blk: {
            const right_node = switch (right.kind) {
                .slice => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .array => |left_node| blk: {
            const right_node = switch (right.kind) {
                .array => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.len, right_node.len) and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .generic => |left_node| blk: {
            const right_node = switch (right.kind) {
                .generic => |node| node,
                else => unreachable,
            };
            if (!std.mem.eql(u8, left_node.base.text, right_node.base.text)) break :blk false;
            if (left_node.args.len != right_node.args.len) break :blk false;
            for (left_node.args, right_node.args) |left_arg, right_arg| {
                if (!sameTypeSyntax(left_arg, right_arg)) break :blk false;
            }
            break :blk true;
        },
        .fn_pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .fn_pointer => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTypeSyntax(left_param, right_param)) break :blk false;
            }
            break :blk sameTypeSyntax(left_node.ret.*, right_node.ret.*);
        },
        .closure_type => |left_node| blk: {
            const right_node = switch (right.kind) {
                .closure_type => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTypeSyntax(left_param, right_param)) break :blk false;
            }
            break :blk sameTypeSyntax(left_node.ret.*, right_node.ret.*);
        },
        .dyn_trait => |left_node| blk: {
            const right_node = switch (right.kind) {
                .dyn_trait => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                std.mem.eql(u8, left_node.trait_name.text, right_node.trait_name.text);
        },
    };
}

fn sameExprSyntax(left: ast.Expr, right: ast.Expr) bool {
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .ident => |left_ident| std.mem.eql(u8, left_ident.text, switch (right.kind) {
            .ident => |right_ident| right_ident.text,
            else => unreachable,
        }),
        .int_literal => |left_text| std.mem.eql(u8, left_text, switch (right.kind) {
            .int_literal => |right_text| right_text,
            else => unreachable,
        }),
        .float_literal => |left_text| std.mem.eql(u8, left_text, switch (right.kind) {
            .float_literal => |right_text| right_text,
            else => unreachable,
        }),
        .string_literal => |left_text| std.mem.eql(u8, left_text, switch (right.kind) {
            .string_literal => |right_text| right_text,
            else => unreachable,
        }),
        .char_literal => |left_text| std.mem.eql(u8, left_text, switch (right.kind) {
            .char_literal => |right_text| right_text,
            else => unreachable,
        }),
        .bool_literal => |left_value| left_value == switch (right.kind) {
            .bool_literal => |right_value| right_value,
            else => unreachable,
        },
        .null_literal, .uninit_literal, .unreachable_expr, .void_literal => true,
        .enum_literal => |left_ident| std.mem.eql(u8, left_ident.text, switch (right.kind) {
            .enum_literal => |right_ident| right_ident.text,
            else => unreachable,
        }),
        .grouped => |left_inner| sameExprSyntax(left_inner.*, switch (right.kind) {
            .grouped => |right_inner| right_inner.*,
            else => unreachable,
        }),
        .unary => |left_node| blk: {
            const right_node = switch (right.kind) {
                .unary => |node| node,
                else => unreachable,
            };
            break :blk left_node.op == right_node.op and sameExprSyntax(left_node.expr.*, right_node.expr.*);
        },
        .binary => |left_node| blk: {
            const right_node = switch (right.kind) {
                .binary => |node| node,
                else => unreachable,
            };
            break :blk left_node.op == right_node.op and sameExprSyntax(left_node.left.*, right_node.left.*) and sameExprSyntax(left_node.right.*, right_node.right.*);
        },
        .cast => |left_node| blk: {
            const right_node = switch (right.kind) {
                .cast => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.value.*, right_node.value.*) and sameTypeSyntax(left_node.ty.*, right_node.ty.*);
        },
        .address_of => |left_inner| sameExprSyntax(left_inner.*, switch (right.kind) {
            .address_of => |right_inner| right_inner.*,
            else => unreachable,
        }),
        .deref => |left_inner| sameExprSyntax(left_inner.*, switch (right.kind) {
            .deref => |right_inner| right_inner.*,
            else => unreachable,
        }),
        .member => |left_node| blk: {
            const right_node = switch (right.kind) {
                .member => |node| node,
                else => unreachable,
            };
            break :blk std.mem.eql(u8, left_node.name.text, right_node.name.text) and sameExprSyntax(left_node.base.*, right_node.base.*);
        },
        .index => |left_node| blk: {
            const right_node = switch (right.kind) {
                .index => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.base.*, right_node.base.*) and sameExprSyntax(left_node.index.*, right_node.index.*);
        },
        .slice => |left_node| blk: {
            const right_node = switch (right.kind) {
                .slice => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.base.*, right_node.base.*) and sameExprSyntax(left_node.start.*, right_node.start.*) and sameExprSyntax(left_node.end.*, right_node.end.*);
        },
        .call => |left_node| blk: {
            const right_node = switch (right.kind) {
                .call => |node| node,
                else => unreachable,
            };
            if (!sameExprSyntax(left_node.callee.*, right_node.callee.*) or left_node.type_args.len != right_node.type_args.len or left_node.args.len != right_node.args.len) break :blk false;
            for (left_node.type_args, right_node.type_args) |left_arg, right_arg| if (!sameTypeSyntax(left_arg, right_arg)) break :blk false;
            for (left_node.args, right_node.args) |left_arg, right_arg| if (!sameExprSyntax(left_arg, right_arg)) break :blk false;
            break :blk true;
        },
        .block => |left_block| blk: {
            const right_block = switch (right.kind) {
                .block => |block| block,
                else => unreachable,
            };
            if (left_block.items.len != 1 or right_block.items.len != 1) break :blk false;
            const left_return = switch (left_block.items[0].kind) {
                .@"return" => |value| value orelse break :blk false,
                else => break :blk false,
            };
            const right_return = switch (right_block.items[0].kind) {
                .@"return" => |value| value orelse break :blk false,
                else => break :blk false,
            };
            break :blk sameExprSyntax(left_return, right_return);
        },
        else => false,
    };
}
