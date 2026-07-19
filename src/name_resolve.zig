const std = @import("std");

const ast = @import("ast.zig");

const QualifiedKey = struct {
    owner: []const u8,
    member: []const u8,
};

const QualifiedKeyContext = struct {
    pub fn hash(_: QualifiedKeyContext, key: QualifiedKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.owner.len));
        hasher.update(key.owner);
        hasher.update(std.mem.asBytes(&key.member.len));
        hasher.update(key.member);
        return hasher.final();
    }

    pub fn eql(_: QualifiedKeyContext, left: QualifiedKey, right: QualifiedKey) bool {
        return std.mem.eql(u8, left.owner, right.owner) and std.mem.eql(u8, left.member, right.member);
    }
};

const QualifiedMap = std.HashMap(QualifiedKey, []const u8, QualifiedKeyContext, 80);

pub fn transform(allocator: std.mem.Allocator, module: ast.Module) !ast.Module {
    var symbols = QualifiedMap.init(allocator);
    defer symbols.deinit();
    for (module.qualified_symbols) |symbol| {
        try symbols.put(.{ .owner = symbol.owner.text, .member = symbol.member.text }, symbol.linkage_name);
    }
    try resolveDecls(&symbols, module.decls);
    return module;
}

fn resolveDecls(symbols: *const QualifiedMap, decls: []ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*decl| switch (decl.kind) {
        .fn_decl, .extern_fn => |*fn_decl| {
            for (fn_decl.params) |*param| try resolveType(symbols, &param.ty);
            if (fn_decl.return_type) |*return_type| try resolveType(symbols, return_type);
            if (fn_decl.body) |*body| try resolveBlock(symbols, body);
        },
        .type_alias => |*alias| try resolveType(symbols, &alias.ty),
        .struct_decl => |*struct_decl| for (struct_decl.fields) |*field| try resolveType(symbols, &field.ty),
        .packed_bits_decl => |*packed_decl| {
            try resolveType(symbols, &packed_decl.repr);
            for (packed_decl.fields) |*field| try resolveType(symbols, &field.ty);
        },
        .overlay_union_decl => |*overlay| for (overlay.fields) |*field| try resolveType(symbols, &field.ty),
        .global_decl => |*global| {
            if (global.ty) |*ty| try resolveType(symbols, ty);
            if (global.init) |*initializer| try resolveExpr(symbols, initializer);
        },
        .enum_decl => |*enum_decl| {
            if (enum_decl.repr) |*repr| try resolveType(symbols, repr);
            for (enum_decl.cases) |*case| if (case.value) |*value| try resolveExpr(symbols, value);
        },
        .union_decl => |*union_decl| for (union_decl.cases) |*case| if (case.ty) |*ty| try resolveType(symbols, ty),
        .trait_decl => |*trait| for (trait.methods) |*method| {
            for (method.params) |*param| try resolveType(symbols, &param.ty);
            if (method.return_type) |*return_type| try resolveType(symbols, return_type);
        },
        .impl_trait => |*impl_trait| for (impl_trait.methods) |*method| {
            for (method.params) |*param| try resolveType(symbols, &param.ty);
            if (method.return_type) |*return_type| try resolveType(symbols, return_type);
        },
        .opaque_decl => {},
    };
}

fn resolveBlock(symbols: *const QualifiedMap, block: *ast.Block) std.mem.Allocator.Error!void {
    for (block.items) |*stmt| try resolveStmt(symbols, stmt);
}

fn resolveStmt(symbols: *const QualifiedMap, stmt: *ast.Stmt) std.mem.Allocator.Error!void {
    switch (stmt.kind) {
        .let_decl, .var_decl => |*local| {
            if (local.ty) |*ty| try resolveType(symbols, ty);
            if (local.init) |*initializer| try resolveExpr(symbols, initializer);
        },
        .loop => |*loop| {
            if (loop.iterable) |*iterable| try resolveExpr(symbols, iterable);
            try resolveBlock(symbols, &loop.body);
        },
        .if_let => |*if_let| {
            try resolveExpr(symbols, &if_let.value);
            try resolvePattern(symbols, &if_let.pattern);
            try resolveBlock(symbols, &if_let.then_block);
            if (if_let.else_block) |*else_block| try resolveBlock(symbols, else_block);
        },
        .@"switch" => |*switch_node| {
            try resolveExpr(symbols, &switch_node.subject);
            for (switch_node.arms) |*arm| {
                for (arm.patterns) |*pattern| try resolvePattern(symbols, pattern);
                switch (arm.body) {
                    .block => |*body| try resolveBlock(symbols, body),
                    .expr => |*expr| try resolveExpr(symbols, expr),
                }
            }
        },
        .unsafe_block, .comptime_block, .block => |*block| try resolveBlock(symbols, block),
        .contract_block => |*contract| try resolveBlock(symbols, &contract.block),
        .@"return" => |*value| if (value.*) |*expr| try resolveExpr(symbols, expr),
        .@"defer", .assert, .expr => |*expr| try resolveExpr(symbols, expr),
        .assignment => |*assignment| {
            try resolveExpr(symbols, &assignment.target);
            try resolveExpr(symbols, &assignment.value);
        },
        .asm_stmt, .@"break", .@"continue" => {},
    }
}

fn resolvePattern(symbols: *const QualifiedMap, pattern: *ast.Pattern) std.mem.Allocator.Error!void {
    if (pattern.kind == .literal) try resolveExpr(symbols, &pattern.kind.literal);
}

fn resolveExpr(symbols: *const QualifiedMap, expr: *ast.Expr) std.mem.Allocator.Error!void {
    switch (expr.kind) {
        .array_literal => |items| for (items) |*item| try resolveExpr(symbols, item),
        .struct_literal => |fields| for (fields) |*field| try resolveExpr(symbols, &field.value),
        .grouped, .address_of, .deref, .await_expr => |inner| try resolveExpr(symbols, inner),
        .block => |*block| try resolveBlock(symbols, block),
        .unary => |*unary_node| try resolveExpr(symbols, unary_node.expr),
        .binary => |*binary| {
            try resolveExpr(symbols, binary.left);
            try resolveExpr(symbols, binary.right);
        },
        .cast => |*cast| {
            try resolveExpr(symbols, cast.value);
            try resolveType(symbols, cast.ty);
        },
        .call => |*call| {
            try resolveExpr(symbols, call.callee);
            for (call.type_args) |*type_arg| try resolveType(symbols, type_arg);
            for (call.args) |*arg| try resolveExpr(symbols, arg);
        },
        .index => |*index| {
            try resolveExpr(symbols, index.base);
            try resolveExpr(symbols, index.index);
        },
        .slice => |*slice| {
            try resolveExpr(symbols, slice.base);
            try resolveExpr(symbols, slice.start);
            try resolveExpr(symbols, slice.end);
        },
        .member => |*member| {
            try resolveExpr(symbols, member.base);
            const owner = switch (member.base.kind) {
                .ident => |id| id,
                else => return,
            };
            const linkage_name = symbols.get(.{ .owner = owner.text, .member = member.name.text }) orelse return;
            const span = joinSpan(member.base.span, member.name.span);
            expr.* = .{ .span = span, .kind = .{ .ident = .{ .text = linkage_name, .span = span } } };
        },
        .try_expr => |*try_expr| {
            try resolveExpr(symbols, try_expr.operand);
            if (try_expr.mapped) |mapped| try resolveExpr(symbols, mapped);
        },
        .ident,
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .uninit_literal,
        .unreachable_expr,
        .void_literal,
        .enum_literal,
        => {},
    }
}

fn resolveType(symbols: *const QualifiedMap, ty: *ast.TypeExpr) std.mem.Allocator.Error!void {
    switch (ty.kind) {
        .array => |*array| {
            try resolveExpr(symbols, &array.len);
            try resolveType(symbols, array.child);
        },
        .pointer => |*pointer| try resolveType(symbols, pointer.child),
        .raw_many_pointer => |*pointer| try resolveType(symbols, pointer.child),
        .slice => |*slice| try resolveType(symbols, slice.child),
        .qualified => |*qualified| try resolveType(symbols, qualified.child),
        .nullable => |child| try resolveType(symbols, child),
        .member => |*member| try resolveType(symbols, member.base),
        .generic => |*generic| for (generic.args) |*arg| try resolveType(symbols, arg),
        .fn_pointer => |*function| {
            for (function.params) |*param| try resolveType(symbols, param);
            try resolveType(symbols, function.ret);
        },
        .closure_type => |*closure| {
            for (closure.params) |*param| try resolveType(symbols, param);
            try resolveType(symbols, closure.ret);
        },
        .name, .enum_literal, .dyn_trait => {},
    }
}

fn joinSpan(start: ast.Span, end: ast.Span) ast.Span {
    const finish = end.offset + end.len;
    return .{
        .offset = start.offset,
        .len = if (finish >= start.offset) finish - start.offset else start.len,
        .line = start.line,
        .column = start.column,
    };
}
