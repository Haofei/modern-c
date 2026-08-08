const std = @import("std");

const ast = @import("ast.zig");

/// Backend-side auto-drop eligibility for concrete AST struct declarations.
/// Sema remains the authority that validates unique `#[drop]` glue; this helper
/// prevents C and LLVM from drifting while deciding whether a validated drop
/// function should be registered for lexical auto-drop emission.
pub fn autoDropEligibleTypeName(
    type_name: []const u8,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) bool {
    const decl = structs.get(type_name) orelse return false;
    if (decl.is_linear) return false;
    if (decl.is_move) return true;
    const self_ty = ast.TypeExpr{ .span = decl.name.span, .kind = .{ .name = decl.name } };
    return typeEmbedsMoveByValue(self_ty, structs, aliases, 0) and
        !typeEmbedsLinearByValue(self_ty, structs, aliases, 0);
}

pub fn typeEmbedsMoveByValue(
    ty: ast.TypeExpr,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
    depth: usize,
) bool {
    if (depth >= 64) return true;
    return switch (ty.kind) {
        .name => |n| blk: {
            if (aliases.get(n.text)) |target| break :blk typeEmbedsMoveByValue(target, structs, aliases, depth + 1);
            const decl = structs.get(n.text) orelse break :blk false;
            if (decl.is_move) break :blk true;
            for (decl.fields) |field| if (typeEmbedsMoveByValue(field.ty, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .generic => |g| blk: {
            if (structs.get(g.base.text)) |decl| if (decl.is_move) break :blk true;
            for (g.args) |arg| if (typeEmbedsMoveByValue(arg, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .array => |node| typeEmbedsMoveByValue(node.child.*, structs, aliases, depth + 1),
        .qualified => |node| typeEmbedsMoveByValue(node.child.*, structs, aliases, depth + 1),
        .nullable => |child| typeEmbedsMoveByValue(child.*, structs, aliases, depth + 1),
        else => false,
    };
}

pub fn typeEmbedsLinearByValue(
    ty: ast.TypeExpr,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
    depth: usize,
) bool {
    if (depth >= 64) return true;
    return switch (ty.kind) {
        .name => |n| blk: {
            if (aliases.get(n.text)) |target| break :blk typeEmbedsLinearByValue(target, structs, aliases, depth + 1);
            const decl = structs.get(n.text) orelse break :blk false;
            if (decl.is_linear) break :blk true;
            for (decl.fields) |field| if (typeEmbedsLinearByValue(field.ty, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .generic => |g| blk: {
            if (structs.get(g.base.text)) |decl| if (decl.is_linear) break :blk true;
            for (g.args) |arg| if (typeEmbedsLinearByValue(arg, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .array => |node| typeEmbedsLinearByValue(node.child.*, structs, aliases, depth + 1),
        .qualified => |node| typeEmbedsLinearByValue(node.child.*, structs, aliases, depth + 1),
        .nullable => |child| typeEmbedsLinearByValue(child.*, structs, aliases, depth + 1),
        else => false,
    };
}
