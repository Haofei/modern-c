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

pub fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |n| n.text,
        .qualified => |q| typeName(q.child.*),
        else => null,
    };
}

pub fn simpleNameType(name: []const u8, span: ast.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
}

pub fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

pub fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

pub fn isOpaqueAddressTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "PAddr") or
        std.mem.eql(u8, name, "VAddr") or
        std.mem.eql(u8, name, "DmaAddr");
}

pub fn isPointerLikeGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "MmioPtr") or
        std.mem.eql(u8, name, "UserPtr");
}

pub fn isArithmeticLayoutGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration");
}

pub fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

pub fn dropPointerReleaseParamTypeName(fn_decl: ast.FnDecl) ?[]const u8 {
    if (fn_decl.params.len == 0) return null;
    const first = fn_decl.params[0].ty;
    const child = switch (first.kind) {
        .pointer => |pointer| blk: {
            if (pointer.mutability != .mut) return null;
            break :blk pointer.child.*;
        },
        else => return null,
    };
    return leadingTypeName(child);
}

pub fn leadingTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .generic => |generic| generic.base.text,
        .qualified => |node| leadingTypeName(node.child.*),
        else => typeName(ty),
    };
}

pub const DmaBufInfo = struct {
    payload: ast.TypeExpr,
    mode: []const u8,
};

pub fn dmaBufInfo(ty: ast.TypeExpr) ?DmaBufInfo {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "DmaBuf") or node.args.len != 2) return null;
            const mode = switch (node.args[1].kind) {
                .enum_literal => |literal| literal.text,
                else => return null,
            };
            return .{ .payload = node.args[0], .mode = mode };
        },
        .qualified => |node| dmaBufInfo(node.child.*),
        else => null,
    };
}

pub fn isStringLiteralTarget(ty: ast.TypeExpr) bool {
    if (typeName(ty)) |name| {
        if (std.mem.eql(u8, name, "cstr")) return true;
    }
    const child = switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        else => return false,
    };
    const name = typeName(child) orelse return false;
    return std.mem.eql(u8, name, "u8");
}

pub fn stringLiteralByteLen(literal: []const u8) ?usize {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const body = literal[1 .. literal.len - 1];
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') {
            n += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) return null;
        switch (body[i]) {
            '\\', '\'', '"', '0', 'n', 'r', 't' => {},
            else => return null,
        }
        n += 1;
    }
    return n;
}

pub fn isMmioStructAbi(struct_decl: ast.StructDecl) bool {
    return if (struct_decl.abi) |abi| std.mem.eql(u8, abi, "mmio") else false;
}

pub fn u8SliceMutability(ty: ast.TypeExpr) ?ast.Mutability {
    const node = switch (ty.kind) {
        .slice => |node| node,
        else => return null,
    };
    const name = typeName(node.child.*) orelse return null;
    if (!std.mem.eql(u8, name, "u8")) return null;
    return node.mutability;
}

pub fn overlayByteArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| {
            const child_name = typeName(node.child.*) orelse return null;
            if (!std.mem.eql(u8, child_name, "u8")) return null;
            return node.child.*;
        },
        .qualified => |node| overlayByteArrayElementType(node.child.*),
        else => null,
    };
}

pub fn overlayArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| overlayArrayElementType(node.child.*),
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
