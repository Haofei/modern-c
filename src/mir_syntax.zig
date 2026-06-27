const std = @import("std");

const ast = @import("ast.zig");

pub fn exprTerminates(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unreachable_expr => true,
        .grouped => |inner| exprTerminates(inner.*),
        .call => |node| isTrapCall(node.callee.*),
        else => false,
    };
}

pub fn exprText(expr: ast.Expr) []const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .int_literal => "int",
        .float_literal => "float",
        .string_literal => "string",
        .char_literal => "char",
        .bool_literal => "bool",
        .null_literal => "null",
        .uninit_literal => "uninit",
        .unreachable_expr => "unreachable",
        .void_literal => "void",
        .enum_literal => |ident| ident.text,
        .array_literal => "array_literal",
        .struct_literal => "struct_literal",
        .call => |node| exprText(node.callee.*),
        .member => |node| memberName(node),
        .grouped => |inner| exprText(inner.*),
        else => @tagName(expr.kind),
    };
}

fn memberName(node: anytype) []const u8 {
    if (node.base.kind == .ident) {
        const base = node.base.kind.ident.text;
        if (std.mem.eql(u8, base, "raw") or std.mem.eql(u8, base, "mmio") or std.mem.eql(u8, base, "atomic") or std.mem.eql(u8, base, "unchecked") or std.mem.eql(u8, base, "compiler")) {
            return node.name.text;
        }
    }
    return node.name.text;
}

pub fn patternText(pattern: ast.Pattern) []const u8 {
    return switch (pattern.kind) {
        .wildcard => "_",
        .bind => |ident| ident.text,
        .tag => |ident| ident.text,
        .tag_bind => |node| node.tag.text,
        .literal => "literal",
    };
}

pub fn typeText(ty: ast.TypeExpr) []const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .enum_literal => |literal| literal.text,
        .member => |node| node.field.text,
        .nullable => "?",
        .qualified => |node| typeText(node.child.*),
        .pointer => |node| pointerTypeTextWithChild(node.mutability, typeText(node.child.*)),
        .raw_many_pointer => |node| rawManyPointerTypeTextWithChild(node.mutability, typeText(node.child.*)),
        .slice => |node| sliceTypeTextWithChild(node.mutability, typeText(node.child.*)),
        .array => "array",
        .generic => |node| node.base.text,
        .fn_pointer => "fn",
        .closure_type => "closure",
        .dyn_trait => |d| d.trait_name.text,
    };
}

fn pointerTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "*",
        .mut => "*mut",
        .@"const" => "*const",
    };
}

fn pointerTypeTextWithChild(mutability: ast.Mutability, child: []const u8) []const u8 {
    if (std.mem.eql(u8, child, "u8")) return switch (mutability) {
        .none => "* u8",
        .mut => "*mut u8",
        .@"const" => "*const u8",
    };
    if (std.mem.eql(u8, child, "u16")) return switch (mutability) {
        .none => "* u16",
        .mut => "*mut u16",
        .@"const" => "*const u16",
    };
    if (std.mem.eql(u8, child, "u32")) return switch (mutability) {
        .none => "* u32",
        .mut => "*mut u32",
        .@"const" => "*const u32",
    };
    if (std.mem.eql(u8, child, "c_void")) return switch (mutability) {
        .none => "* c_void",
        .mut => "*mut c_void",
        .@"const" => "*const c_void",
    };
    return pointerTypeText(mutability);
}

fn rawManyPointerTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "[*]",
        .mut => "[*]mut",
        .@"const" => "[*]const",
    };
}

fn rawManyPointerTypeTextWithChild(mutability: ast.Mutability, child: []const u8) []const u8 {
    if (std.mem.eql(u8, child, "u8")) return switch (mutability) {
        .none => "[*] u8",
        .mut => "[*]mut u8",
        .@"const" => "[*]const u8",
    };
    if (std.mem.eql(u8, child, "u16")) return switch (mutability) {
        .none => "[*] u16",
        .mut => "[*]mut u16",
        .@"const" => "[*]const u16",
    };
    if (std.mem.eql(u8, child, "u32")) return switch (mutability) {
        .none => "[*] u32",
        .mut => "[*]mut u32",
        .@"const" => "[*]const u32",
    };
    if (std.mem.eql(u8, child, "c_void")) return switch (mutability) {
        .none => "[*] c_void",
        .mut => "[*]mut c_void",
        .@"const" => "[*]const c_void",
    };
    return rawManyPointerTypeText(mutability);
}

fn sliceTypeText(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "[]",
        .mut => "[]mut",
        .@"const" => "[]const",
    };
}

fn sliceTypeTextWithChild(mutability: ast.Mutability, child: []const u8) []const u8 {
    if (std.mem.eql(u8, child, "u8")) return switch (mutability) {
        .none => "[] u8",
        .mut => "[]mut u8",
        .@"const" => "[]const u8",
    };
    if (std.mem.eql(u8, child, "u16")) return switch (mutability) {
        .none => "[] u16",
        .mut => "[]mut u16",
        .@"const" => "[]const u16",
    };
    if (std.mem.eql(u8, child, "u32")) return switch (mutability) {
        .none => "[] u32",
        .mut => "[]mut u32",
        .@"const" => "[]const u32",
    };
    if (std.mem.eql(u8, child, "c_void")) return switch (mutability) {
        .none => "[] c_void",
        .mut => "[]mut c_void",
        .@"const" => "[]const c_void",
    };
    return sliceTypeText(mutability);
}

pub fn isTrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "trap"),
        .grouped => |inner| isTrapCall(inner.*),
        else => false,
    };
}

pub fn isUnwrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "unwrap"),
        .grouped => |inner| isUnwrapCall(inner.*),
        else => false,
    };
}

pub fn directCalleeName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .member => |node| qualifiedMemberName(node),
        .grouped => |inner| directCalleeName(inner.*),
        else => null,
    };
}

pub fn directIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| directIdentName(inner.*),
        else => null,
    };
}

pub fn assignmentTargetIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |id| id.text,
        .grouped => |inner| assignmentTargetIdentName(inner.*),
        else => null,
    };
}

pub fn enumLiteralText(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |ident| ident.text,
        .grouped => |inner| enumLiteralText(inner.*),
        else => null,
    };
}

pub fn constGetBase(call: anytype) ?*ast.Expr {
    if (call.args.len != 0 or call.type_args.len != 1) return null;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, member.name.text, "const_get")) return null;
    return member.base;
}

fn qualifiedMemberName(node: anytype) ?[]const u8 {
    if (std.mem.eql(u8, node.name.text, "offset")) return "ptr.offset";
    if (node.base.kind != .ident) return node.name.text;
    const base = node.base.kind.ident.text;
    if (std.mem.eql(u8, base, "lock") and std.mem.eql(u8, node.name.text, "acquire")) return "lock.acquire";
    if (std.mem.eql(u8, base, "heap") and std.mem.eql(u8, node.name.text, "alloc")) return "heap.alloc";
    if (std.mem.eql(u8, base, "device") and std.mem.eql(u8, node.name.text, "wait_irq")) return "device.wait_irq";
    if (std.mem.eql(u8, base, "fs") and std.mem.eql(u8, node.name.text, "read")) return "fs.read";
    if (std.mem.eql(u8, base, "wrapping")) {
        if (std.mem.eql(u8, node.name.text, "add")) return "wrapping.add";
        if (std.mem.eql(u8, node.name.text, "sub")) return "wrapping.sub";
        if (std.mem.eql(u8, node.name.text, "mul")) return "wrapping.mul";
        if (std.mem.eql(u8, node.name.text, "neg")) return "wrapping.neg";
    }
    if (std.mem.eql(u8, base, "saturating")) {
        if (std.mem.eql(u8, node.name.text, "add")) return "saturating.add";
        if (std.mem.eql(u8, node.name.text, "sub")) return "saturating.sub";
        if (std.mem.eql(u8, node.name.text, "mul")) return "saturating.mul";
    }
    if (std.mem.eql(u8, base, "unchecked")) {
        if (std.mem.eql(u8, node.name.text, "add")) return "unchecked.add";
        if (std.mem.eql(u8, node.name.text, "sub")) return "unchecked.sub";
        if (std.mem.eql(u8, node.name.text, "mul")) return "unchecked.mul";
        return node.name.text;
    }
    if (std.mem.eql(u8, base, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked")) return "compiler.assume_noalias_unchecked";
    if (std.mem.eql(u8, base, "raw")) {
        if (std.mem.eql(u8, node.name.text, "store")) return "raw.store";
        if (std.mem.eql(u8, node.name.text, "load")) return "raw.load";
    }
    if (std.mem.eql(u8, base, "mmio")) {
        if (std.mem.eql(u8, node.name.text, "read")) return "mmio.read";
        if (std.mem.eql(u8, node.name.text, "write")) return "mmio.write";
        if (std.mem.eql(u8, node.name.text, "map")) return "mmio.map";
    }
    if (std.mem.eql(u8, base, "atomic")) {
        if (std.mem.eql(u8, node.name.text, "init")) return "atomic.init";
        if (std.mem.eql(u8, node.name.text, "load")) return "atomic.load";
        if (std.mem.eql(u8, node.name.text, "store")) return "atomic.store";
        if (std.mem.eql(u8, node.name.text, "rmw")) return "atomic.rmw";
        if (std.mem.eql(u8, node.name.text, "fetch_add")) return "atomic.fetch_add";
        if (std.mem.eql(u8, node.name.text, "fetch_sub")) return "atomic.fetch_sub";
    }
    return node.name.text;
}
