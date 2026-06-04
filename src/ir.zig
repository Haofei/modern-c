const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

pub const FactKind = enum {
    checked_arithmetic_trap,
    no_lang_trap_index,
    unsafe_contract_begin,
    unsafe_contract_end,
    unchecked_call,
    mmio_read_call,
    mmio_write_call,
    direct_mmio_assignment,
    assignment,
    store,
};

pub const Collector = struct {
    pub fn appendFacts(
        allocator: std.mem.Allocator,
        module: ast.Module,
        out: *std.ArrayList(u8),
    ) anyerror!void {
        var writer: ListFactWriter = .{ .allocator = allocator, .out = out };
        try writeModuleFacts(module, &writer);
    }

    pub fn writeFacts(module: ast.Module, writer: anytype) !void {
        try writeModuleFacts(module, writer);
    }
};

pub fn appendFacts(
    allocator: std.mem.Allocator,
    module: ast.Module,
    out: *std.ArrayList(u8),
) anyerror!void {
    try Collector.appendFacts(allocator, module, out);
}

pub fn writeFacts(module: ast.Module, writer: anytype) !void {
    try Collector.writeFacts(module, writer);
}

const Context = struct {
    function_name: []const u8 = "",
    no_lang_trap: bool = false,
    unsafe_contract_depth: usize = 0,
};

const ListFactWriter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),

    pub fn print(self: *ListFactWriter, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.out.print(self.allocator, fmt, args);
    }
};

fn writeModuleFacts(module: ast.Module, writer: anytype) anyerror!void {
    for (module.decls) |decl| try writeDeclFacts(decl, writer);
}

fn writeDeclFacts(decl: ast.Decl, writer: anytype) anyerror!void {
    switch (decl.kind) {
        .fn_decl, .extern_fn => |fn_decl| {
            if (fn_decl.body) |body| {
                try writeBlockFacts(body, writer, .{
                    .function_name = fn_decl.name.text,
                    .no_lang_trap = hasNoLangTrap(decl.attrs),
                });
            }
        },
        .type_alias, .extern_struct, .opaque_decl => {},
    }
}

fn writeBlockFacts(block: ast.Block, writer: anytype, ctx: Context) anyerror!void {
    for (block.items) |stmt| try writeStmtFacts(stmt, writer, ctx);
}

fn writeStmtFacts(stmt: ast.Stmt, writer: anytype, ctx: Context) anyerror!void {
    switch (stmt.kind) {
        .let_decl, .var_decl => |local| {
            if (local.init) |expr| try writeExprFacts(expr, writer, ctx);
        },
        .loop => |node| {
            if (node.iterable) |iterable| try writeExprFacts(iterable, writer, ctx);
            try writeBlockFacts(node.body, writer, ctx);
        },
        .if_let => |node| {
            try writeExprFacts(node.value, writer, ctx);
            try writeBlockFacts(node.then_block, writer, ctx);
            if (node.else_block) |else_block| try writeBlockFacts(else_block, writer, ctx);
        },
        .@"switch" => |node| {
            try writeExprFacts(node.subject, writer, ctx);
            for (node.arms) |arm| switch (arm.body) {
                .block => |body| try writeBlockFacts(body, writer, ctx),
                .expr => |expr| try writeExprFacts(expr, writer, ctx),
            };
        },
        .unsafe_block, .block => |body| try writeBlockFacts(body, writer, ctx),
        .contract_block => |contract| {
            try writeContractBoundary(.unsafe_contract_begin, contract.attr, writer, ctx);
            var next = ctx;
            next.unsafe_contract_depth += 1;
            try writeBlockFacts(contract.block, writer, next);
            try writeContractBoundary(.unsafe_contract_end, contract.attr, writer, ctx);
        },
        .asm_stmt => {},
        .@"return" => |maybe| {
            if (maybe) |expr| try writeExprFacts(expr, writer, ctx);
        },
        .@"defer", .expr => |expr| try writeExprFacts(expr, writer, ctx),
        .assert => |expr| {
            if (ctx.no_lang_trap) {
                try writer.print(
                    "fact no_lang_trap_assert fn={s} unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.unsafe_contract_depth, stmt.span.line, stmt.span.column },
                );
            }
            try writeExprFacts(expr, writer, ctx);
        },
        .assignment => |node| {
            const kind: FactKind = if (isMemberExpr(node.target)) .direct_mmio_assignment else .assignment;
            try writeAssignmentFact(kind, stmt.span, node.target, writer, ctx);
            if (isStoreTarget(node.target)) {
                try writeAssignmentFact(.store, stmt.span, node.target, writer, ctx);
            }
            try writeExprFacts(node.target, writer, ctx);
            try writeExprFacts(node.value, writer, ctx);
        },
    }
}

fn writeExprFacts(expr: ast.Expr, writer: anytype, ctx: Context) anyerror!void {
    switch (expr.kind) {
        .ident,
        .int_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .uninit_literal,
        .void_literal,
        .enum_literal,
        => {},
        .unreachable_expr => {
            if (ctx.no_lang_trap) {
                try writer.print(
                    "fact no_lang_trap_unreachable fn={s} unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                );
            }
        },
        .grouped, .address_of, .deref, .try_expr => |inner| try writeExprFacts(inner.*, writer, ctx),
        .block => |body| try writeBlockFacts(body, writer, ctx),
        .unary => |node| try writeExprFacts(node.expr.*, writer, ctx),
        .binary => |node| {
            if (isCheckedTrapOp(node.op)) {
                try writeCheckedArithmeticFact(expr.span, node.op, writer, ctx);
            }
            try writeExprFacts(node.left.*, writer, ctx);
            try writeExprFacts(node.right.*, writer, ctx);
        },
        .cast => |node| try writeExprFacts(node.value.*, writer, ctx),
        .call => |node| {
            try writeCallFact(expr.span, node.callee.*, node.args, writer, ctx);
            try writeExprFacts(node.callee.*, writer, ctx);
            for (node.args) |arg| try writeExprFacts(arg, writer, ctx);
        },
        .index => |node| {
            if (ctx.no_lang_trap) {
                try writeIndexFact(expr.span, writer, ctx);
            }
            try writeExprFacts(node.base.*, writer, ctx);
            try writeExprFacts(node.index.*, writer, ctx);
        },
        .member => |node| try writeExprFacts(node.base.*, writer, ctx),
    }
}

fn writeCheckedArithmeticFact(span: ast.Span, op: ast.BinaryOp, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact checked_arithmetic_trap fn={s} op={s} no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, @tagName(op), ctx.no_lang_trap, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeIndexFact(span: ast.Span, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact no_lang_trap_index fn={s} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeContractBoundary(kind: FactKind, attr: ast.Attr, writer: anytype, ctx: Context) anyerror!void {
    const contract_name = switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named => "",
    };
    try writer.print(
        "fact {s} fn={s} contract={s} unsafe_contract_depth={} line={} column={}\n",
        .{ @tagName(kind), ctx.function_name, contract_name, ctx.unsafe_contract_depth, attr.span.line, attr.span.column },
    );
}

fn writeCallFact(span: ast.Span, callee: ast.Expr, args: []ast.Expr, writer: anytype, ctx: Context) anyerror!void {
    if (isUncheckedCall(callee)) {
        try writer.print(
            "fact unchecked_call fn={s} callee=",
            .{ctx.function_name},
        );
        try writeExprName(callee, writer);
        try writer.print(
            " unsafe_contract_depth={} line={} column={}\n",
            .{ ctx.unsafe_contract_depth, span.line, span.column },
        );
    }

    if (mmioCallKind(callee)) |kind| {
        try writer.print(
            "fact {s} fn={s} callee=",
            .{ @tagName(kind), ctx.function_name },
        );
        try writeExprName(callee, writer);
        try writer.print(" ordering=", .{});
        try writeOrderingArg(args, writer);
        try writer.print(
            " unsafe_contract_depth={} line={} column={}\n",
            .{ ctx.unsafe_contract_depth, span.line, span.column },
        );
    }
}

fn writeAssignmentFact(kind: FactKind, span: ast.Span, target: ast.Expr, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact {s} fn={s} target=",
        .{ @tagName(kind), ctx.function_name },
    );
    try writeExprName(target, writer);
    try writer.print(
        " unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeOrderingArg(args: []ast.Expr, writer: anytype) anyerror!void {
    for (args) |arg| {
        if (arg.kind == .enum_literal) {
            try writer.print(".{s}", .{arg.kind.enum_literal.text});
            return;
        }
    }
    try writer.print("unknown", .{});
}

fn writeExprName(expr: ast.Expr, writer: anytype) anyerror!void {
    switch (expr.kind) {
        .ident => |ident| try writer.print("{s}", .{ident.text}),
        .enum_literal => |literal| try writer.print(".{s}", .{literal.text}),
        .member => |node| {
            try writeExprName(node.base.*, writer);
            try writer.print(".{s}", .{node.name.text});
        },
        .call => |node| {
            try writeExprName(node.callee.*, writer);
            try writer.print("()", .{});
        },
        .index => |node| {
            try writeExprName(node.base.*, writer);
            try writer.print("[]", .{});
        },
        .deref => |inner| {
            try writeExprName(inner.*, writer);
            try writer.print(".*", .{});
        },
        .grouped, .address_of, .try_expr => |inner| try writeExprName(inner.*, writer),
        else => try writer.print("<expr>", .{}),
    }
}

test "writes early inspection facts for parser AST" {
    const source =
        \\#[no_lang_trap]
        \\fn trap_edges(buf: []const u8, i: usize, flag: bool) -> u8 {
        \\    assert(flag);
        \\    return buf[i + 1];
        \\}
        \\
        \\fn contracts(uart: MmioPtr<Uart16550>, ch: u8) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let x = unchecked.add(ch, 1);
        \\    }
        \\    uart.thr.write(ch, .release);
        \\    uart.thr = ch;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "ir_facts.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendFacts(std.testing.allocator, module, &facts);

    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact no_lang_trap_assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact checked_arithmetic_trap") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact no_lang_trap_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact unsafe_contract_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact unchecked_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact mmio_write_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact direct_mmio_assignment") != null);
}

fn hasNoLangTrap(attrs: []ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .no_lang_trap) return true;
    }
    return false;
}

fn isCheckedTrapOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl => true,
        else => false,
    };
}

fn isUncheckedCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| isIdentNamed(node.base.*, "unchecked"),
        .ident => |ident| std.mem.startsWith(u8, ident.text, "unchecked_"),
        else => false,
    };
}

fn mmioCallKind(callee: ast.Expr) ?FactKind {
    return switch (callee.kind) {
        .member => |node| {
            if (std.mem.eql(u8, node.name.text, "read")) return .mmio_read_call;
            if (std.mem.eql(u8, node.name.text, "write")) return .mmio_write_call;
            return null;
        },
        else => null,
    };
}

fn isMemberExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .member => true,
        .grouped => |inner| isMemberExpr(inner.*),
        else => false,
    };
}

fn isStoreTarget(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .deref, .index => true,
        .grouped => |inner| isStoreTarget(inner.*),
        else => false,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
}
