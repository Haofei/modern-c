const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

pub const Instruction = struct {
    kind: []const u8,
    detail: []const u8,
    ty: []const u8,
    line: usize,
    column: usize,
};

pub const Block = struct {
    id: usize,
    kind: []const u8,
    instructions: []Instruction,
    successors: []usize,
};

pub const Function = struct {
    name: []const u8,
    return_ty: []const u8,
    no_lang_trap: bool,
    blocks: []Block,
};

pub const VerificationFinding = struct {
    function_name: []const u8,
    kind: []const u8,
    detail: []const u8,
    line: usize,
    column: usize,
};

const SourcePoint = struct {
    line: usize,
    column: usize,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    functions: []Function,

    pub fn deinit(self: *Module) void {
        for (self.functions) |function| {
            for (function.blocks) |block| {
                self.allocator.free(block.instructions);
                self.allocator.free(block.successors);
            }
            self.allocator.free(function.blocks);
        }
        self.allocator.free(self.functions);
    }
};

pub fn build(allocator: std.mem.Allocator, module: ast.Module) !Module {
    var function_summaries = std.StringHashMap(bool).init(allocator);
    defer function_summaries.deinit();

    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                try function_summaries.put(fn_decl.name.text, hasNoLangTrap(decl.attrs));
            },
            else => {},
        }
    }

    var functions: std.ArrayList(Function) = .empty;
    errdefer {
        for (functions.items) |function| {
            for (function.blocks) |block| {
                allocator.free(block.instructions);
                allocator.free(block.successors);
            }
            allocator.free(function.blocks);
        }
        functions.deinit(allocator);
    }

    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                if (fn_decl.body) |body| {
                    var builder = try FunctionBuilder.init(allocator, fn_decl, hasNoLangTrap(decl.attrs), &function_summaries);
                    errdefer builder.deinit();
                    try builder.buildBody(body);
                    try functions.append(allocator, try builder.finish());
                }
            },
            else => {},
        }
    }

    return .{ .allocator = allocator, .functions = try functions.toOwnedSlice(allocator) };
}

pub fn appendDump(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var hir = try build(allocator, module);
    defer hir.deinit();

    for (hir.functions) |function| {
        try out.print(
            allocator,
            "hir function name={s} return={s} no_lang_trap={} blocks={}\n",
            .{ function.name, function.return_ty, function.no_lang_trap, function.blocks.len },
        );
        for (function.blocks) |block| {
            try out.print(allocator, "hir block fn={s} id={} kind={s} successors=", .{ function.name, block.id, block.kind });
            for (block.successors, 0..) |successor, i| {
                if (i != 0) try out.append(allocator, ',');
                try out.print(allocator, "{}", .{successor});
            }
            try out.append(allocator, '\n');
            for (block.instructions) |instruction| {
                try out.print(
                    allocator,
                    "hir instr fn={s} block={} kind={s} detail={s} type={s} line={} column={}\n",
                    .{ function.name, block.id, instruction.kind, instruction.detail, instruction.ty, instruction.line, instruction.column },
                );
            }
        }
    }
}

pub fn appendVerificationFacts(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var hir = try build(allocator, module);
    defer hir.deinit();

    for (hir.functions) |function| {
        if (!std.mem.eql(u8, function.return_ty, "void")) {
            if (functionFallsThrough(function)) |span| {
                try out.print(
                    allocator,
                    "hir verify fn={s} finding=fallthrough line={} column={}\n",
                    .{ function.name, span.line, span.column },
                );
            }
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (std.mem.eql(u8, instruction.kind, "trap_edge")) {
                    try out.print(
                        allocator,
                        "hir verify fn={s} finding=trap_edge detail={s} no_lang_trap={} line={} column={}\n",
                        .{ function.name, instruction.detail, function.no_lang_trap, instruction.line, instruction.column },
                    );
                }
            }
        }
    }
}

pub fn verify(allocator: std.mem.Allocator, module: ast.Module, reporter: *diagnostics.Reporter) !void {
    var hir = try build(allocator, module);
    defer hir.deinit();

    for (hir.functions) |function| {
        if (!std.mem.eql(u8, function.return_ty, "void")) {
            if (functionFallsThrough(function)) |point| {
                const code = if (std.mem.eql(u8, function.return_ty, "never")) "E_NEVER_FALLTHROUGH" else "E_RETURN_MISSING";
                reporter.err(
                    sourcePointSpan(point),
                    "{s}: HIR verifier found function fallthrough before C emission",
                    .{code},
                );
            }
        }
        if (!function.no_lang_trap) continue;
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (!std.mem.eql(u8, instruction.kind, "trap_edge")) continue;
                reporter.err(
                    .{ .offset = 0, .len = 0, .line = instruction.line, .column = instruction.column },
                    "E_NO_LANG_TRAP_EDGE: HIR verifier found language trap edge {s} before C emission",
                    .{instruction.detail},
                );
            }
        }
    }
}

const MutableBlock = struct {
    id: usize,
    kind: []const u8,
    instructions: std.ArrayList(Instruction) = .empty,
    successors: std.ArrayList(usize) = .empty,
};

const FunctionBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    return_ty: []const u8,
    no_lang_trap: bool,
    function_summaries: *const std.StringHashMap(bool),
    blocks: std.ArrayList(MutableBlock),
    wrap_values: std.StringHashMap(void),
    sat_values: std.StringHashMap(void),
    current: usize,

    fn init(allocator: std.mem.Allocator, fn_decl: ast.FnDecl, no_lang_trap: bool, function_summaries: *const std.StringHashMap(bool)) !FunctionBuilder {
        var blocks: std.ArrayList(MutableBlock) = .empty;
        try blocks.append(allocator, .{ .id = 0, .kind = "entry" });
        var builder = FunctionBuilder{
            .allocator = allocator,
            .name = fn_decl.name.text,
            .return_ty = if (fn_decl.return_type) |ty| typeText(ty) else "void",
            .no_lang_trap = no_lang_trap,
            .function_summaries = function_summaries,
            .blocks = blocks,
            .wrap_values = std.StringHashMap(void).init(allocator),
            .sat_values = std.StringHashMap(void).init(allocator),
            .current = 0,
        };
        for (fn_decl.params) |param| {
            if (isWrapType(param.ty)) try builder.wrap_values.put(param.name.text, {});
            if (isSatType(param.ty)) try builder.sat_values.put(param.name.text, {});
        }
        return builder;
    }

    fn deinit(self: *FunctionBuilder) void {
        for (self.blocks.items) |*block| {
            block.instructions.deinit(self.allocator);
            block.successors.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
        self.wrap_values.deinit();
        self.sat_values.deinit();
    }

    fn finish(self: *FunctionBuilder) !Function {
        var blocks: std.ArrayList(Block) = .empty;
        errdefer {
            for (blocks.items) |block| {
                self.allocator.free(block.instructions);
                self.allocator.free(block.successors);
            }
            blocks.deinit(self.allocator);
        }

        for (self.blocks.items) |*block| {
            try blocks.append(self.allocator, .{
                .id = block.id,
                .kind = block.kind,
                .instructions = try block.instructions.toOwnedSlice(self.allocator),
                .successors = try block.successors.toOwnedSlice(self.allocator),
            });
        }
        self.blocks.deinit(self.allocator);
        self.blocks = .empty;
        self.wrap_values.deinit();
        self.wrap_values = std.StringHashMap(void).init(self.allocator);
        self.sat_values.deinit();
        self.sat_values = std.StringHashMap(void).init(self.allocator);

        return .{
            .name = self.name,
            .return_ty = self.return_ty,
            .no_lang_trap = self.no_lang_trap,
            .blocks = try blocks.toOwnedSlice(self.allocator),
        };
    }

    fn buildBody(self: *FunctionBuilder, body: ast.Block) anyerror!void {
        _ = try self.buildBlock(body);
    }

    fn buildBlock(self: *FunctionBuilder, block: ast.Block) anyerror!bool {
        for (block.items) |stmt| {
            if (try self.buildStmt(stmt)) return true;
        }
        return false;
    }

    fn buildStmt(self: *FunctionBuilder, stmt: ast.Stmt) anyerror!bool {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                for (local.names) |name| try self.addInstr("local", name.text, if (local.ty) |ty| typeText(ty) else "inferred", stmt.span);
                if (local.ty) |ty| {
                    if (isWrapType(ty)) {
                        for (local.names) |name| try self.wrap_values.put(name.text, {});
                    }
                    if (isSatType(ty)) {
                        for (local.names) |name| try self.sat_values.put(name.text, {});
                    }
                }
                if (local.init) |expr| try self.buildExpr(expr);
                return false;
            },
            .assignment => |node| {
                try self.addInstr("assign", exprText(node.target), "unknown", stmt.span);
                try self.buildExpr(node.target);
                try self.buildExpr(node.value);
                return false;
            },
            .expr => |expr| {
                try self.buildExpr(expr);
                return exprTerminates(expr);
            },
            .assert => |expr| {
                try self.addInstr("assert", "condition", "bool", stmt.span);
                try self.addInstr("trap_edge", "Assert", "language_trap", stmt.span);
                try self.buildExpr(expr);
                return false;
            },
            .@"return" => |maybe| {
                if (maybe) |expr| try self.buildExpr(expr);
                try self.addInstr("return", if (maybe) |_| "value" else "void", self.return_ty, stmt.span);
                return true;
            },
            .@"break" => {
                try self.addInstr("break", "loop", "never", stmt.span);
                return true;
            },
            .@"continue" => {
                try self.addInstr("continue", "loop", "never", stmt.span);
                return true;
            },
            .asm_stmt => {
                try self.addInstr("asm", "opaque", "target_effect", stmt.span);
                return true;
            },
            .@"defer" => |expr| {
                try self.addInstr("defer", "cleanup", "void", stmt.span);
                try self.buildExpr(expr);
                return false;
            },
            .block, .unsafe_block, .comptime_block => |body| return try self.buildBlock(body),
            .contract_block => |contract| {
                try self.addInstr("contract_begin", contractName(contract.attr), "contract", contract.attr.span);
                const terminated = try self.buildBlock(contract.block);
                try self.addInstr("contract_end", contractName(contract.attr), "contract", stmt.span);
                return terminated;
            },
            .if_let => |node| return try self.buildIfLet(node, stmt.span),
            .@"switch" => |node| return try self.buildSwitch(node, stmt.span),
            .loop => |node| return try self.buildLoop(node, stmt.span),
        }
    }

    fn buildIfLet(self: *FunctionBuilder, node: ast.IfLet, span: ast.Span) anyerror!bool {
        try self.addInstr("branch_if_let", patternText(node.pattern), "bool", span);
        try self.buildExpr(node.value);

        const then_id = try self.addBlock("if_then");
        const else_id = try self.addBlock(if (node.else_block == null) "if_after" else "if_else");
        const after_id = if (node.else_block == null) else_id else try self.addBlock("if_after");
        try self.addSuccessor(self.current, then_id);
        try self.addSuccessor(self.current, else_id);

        self.current = then_id;
        const then_term = try self.buildBlock(node.then_block);
        if (!then_term) try self.addSuccessor(self.current, after_id);

        if (node.else_block) |else_block| {
            self.current = else_id;
            const else_term = try self.buildBlock(else_block);
            if (!else_term) try self.addSuccessor(self.current, after_id);
        }

        self.current = after_id;
        return false;
    }

    fn buildSwitch(self: *FunctionBuilder, node: ast.Switch, span: ast.Span) anyerror!bool {
        try self.addInstr("switch", "subject", "branch", span);
        try self.buildExpr(node.subject);

        const dispatch_id = self.current;
        const after_id = try self.addBlock("switch_after");
        for (node.arms, 0..) |arm, i| {
            const arm_id = try self.addBlock("switch_arm");
            try self.addSuccessor(dispatch_id, arm_id);
            self.current = arm_id;
            try self.addInstr("switch_pattern", if (arm.patterns.len == 0) "_" else patternText(arm.patterns[0]), "pattern", span);
            const terminated = switch (arm.body) {
                .block => |body| try self.buildBlock(body),
                .expr => |expr| blk: {
                    try self.buildExpr(expr);
                    break :blk exprTerminates(expr);
                },
            };
            if (!terminated) try self.addSuccessor(self.current, after_id);
            _ = i;
        }
        self.current = after_id;
        return false;
    }

    fn buildLoop(self: *FunctionBuilder, node: ast.Loop, span: ast.Span) anyerror!bool {
        try self.addInstr("loop", @tagName(node.kind), "branch", span);
        if (node.iterable) |iterable| try self.buildExpr(iterable);
        const body_id = try self.addBlock("loop_body");
        const after_id = try self.addBlock("loop_after");
        try self.addSuccessor(self.current, body_id);
        if (node.kind == .@"while") try self.addSuccessor(self.current, after_id);
        self.current = body_id;
        const terminated = try self.buildBlock(node.body);
        if (!terminated) try self.addSuccessor(self.current, body_id);
        self.current = after_id;
        return false;
    }

    fn buildExpr(self: *FunctionBuilder, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .ident, .int_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .null_literal, .uninit_literal, .void_literal, .enum_literal => {
                try self.addInstr("expr", exprText(expr), "value", expr.span);
            },
            .array_literal => |items| {
                try self.addInstr("array_literal", "target_typed", "value", expr.span);
                for (items) |item| try self.buildExpr(item);
            },
            .struct_literal => |fields| {
                try self.addInstr("struct_literal", "target_typed", "value", expr.span);
                for (fields) |field| try self.buildExpr(field.value);
            },
            .unreachable_expr => {
                try self.addInstr("trap_edge", "Unreachable", "language_trap", expr.span);
                try self.addInstr("trap", "Unreachable", "never", expr.span);
            },
            .grouped, .address_of, .deref => |inner| try self.buildExpr(inner.*),
            .try_expr => |inner| {
                try self.addInstr("trap_edge", "Unwrap", "language_trap", expr.span);
                try self.buildExpr(inner.*);
            },
            .block => |block| _ = try self.buildBlock(block),
            .unary => |node| {
                try self.addInstr("unary", @tagName(node.op), "value", expr.span);
                if (node.op == .neg and !self.exprIsWrap(node.expr.*)) try self.addInstr("trap_edge", "IntegerOverflow", "language_trap", expr.span);
                try self.buildExpr(node.expr.*);
            },
            .binary => |node| {
                try self.addInstr("binary", @tagName(node.op), "value", expr.span);
                if (binaryMayTrap(node.op) and !self.binaryIsNoTrapArithmeticDomain(node)) {
                    try self.addInstr("trap_edge", binaryTrapKind(node.op), "language_trap", expr.span);
                }
                try self.buildExpr(node.left.*);
                try self.buildExpr(node.right.*);
            },
            .cast => |node| {
                try self.addInstr("cast", "value", typeText(node.ty.*), expr.span);
                try self.buildExpr(node.value.*);
            },
            .call => |node| {
                try self.addInstr("call", exprText(node.callee.*), "call_result", expr.span);
                if (isTrapCall(node.callee.*)) try self.addInstr("trap_edge", "ExplicitTrap", "language_trap", expr.span);
                if (isUnwrapCall(node.callee.*)) try self.addInstr("trap_edge", "Unwrap", "language_trap", expr.span);
                if (self.no_lang_trap) {
                    if (directCalleeName(node.callee.*)) |callee_name| {
                        if (self.function_summaries.get(callee_name)) |callee_no_lang_trap| {
                            if (!callee_no_lang_trap) try self.addInstr("trap_edge", "CallMayTrap", "language_trap", expr.span);
                        }
                    }
                }
                try self.buildExpr(node.callee.*);
                for (node.args) |arg| try self.buildExpr(arg);
            },
            .index => |node| {
                try self.addInstr("index", "bounds_checked", "value", expr.span);
                try self.addInstr("trap_edge", "Bounds", "language_trap", expr.span);
                try self.buildExpr(node.base.*);
                try self.buildExpr(node.index.*);
            },
            .member => |node| {
                try self.addInstr("member", node.name.text, "value", expr.span);
                try self.buildExpr(node.base.*);
            },
        }
    }

    fn addBlock(self: *FunctionBuilder, kind: []const u8) !usize {
        const id = self.blocks.items.len;
        try self.blocks.append(self.allocator, .{ .id = id, .kind = kind });
        return id;
    }

    fn addSuccessor(self: *FunctionBuilder, from: usize, to: usize) !void {
        for (self.blocks.items[from].successors.items) |existing| {
            if (existing == to) return;
        }
        try self.blocks.items[from].successors.append(self.allocator, to);
    }

    fn addInstr(self: *FunctionBuilder, kind: []const u8, detail: []const u8, ty: []const u8, span: ast.Span) !void {
        try self.blocks.items[self.current].instructions.append(self.allocator, .{
            .kind = kind,
            .detail = detail,
            .ty = ty,
            .line = span.line,
            .column = span.column,
        });
    }

    fn exprIsWrap(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.wrap_values.contains(ident.text),
            .grouped => |inner| self.exprIsWrap(inner.*),
            .binary => |node| isWrapPreservingBinary(node.op) and self.exprIsWrap(node.left.*) and self.exprIsWrap(node.right.*),
            else => false,
        };
    }

    fn exprIsSat(self: *FunctionBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.sat_values.contains(ident.text),
            .grouped => |inner| self.exprIsSat(inner.*),
            .binary => |node| isSatPreservingBinary(node.op) and self.exprIsSat(node.left.*) and self.exprIsSat(node.right.*),
            else => false,
        };
    }

    fn binaryIsNoTrapArithmeticDomain(self: *FunctionBuilder, node: anytype) bool {
        if (isWrapPreservingBinary(node.op) and self.exprIsWrap(node.left.*) and self.exprIsWrap(node.right.*)) return true;
        if (isSatPreservingBinary(node.op) and self.exprIsSat(node.left.*) and self.exprIsSat(node.right.*)) return true;
        return false;
    }
};

fn exprTerminates(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unreachable_expr => true,
        .grouped => |inner| exprTerminates(inner.*),
        .call => |node| isTrapCall(node.callee.*),
        else => false,
    };
}

fn functionFallsThrough(function: Function) ?SourcePoint {
    var stack_buf: [256]usize = undefined;
    var seen_buf: [256]bool = [_]bool{false} ** 256;
    if (function.blocks.len > stack_buf.len) return null;

    var stack_len: usize = 1;
    stack_buf[0] = 0;
    seen_buf[0] = true;

    while (stack_len > 0) {
        stack_len -= 1;
        const id = stack_buf[stack_len];
        const block = function.blocks[id];
        if (block.successors.len == 0 and !blockHasTerminator(block)) {
            return blockLastSpan(block);
        }
        for (block.successors) |successor| {
            if (successor >= function.blocks.len or seen_buf[successor]) continue;
            seen_buf[successor] = true;
            stack_buf[stack_len] = successor;
            stack_len += 1;
        }
    }
    return null;
}

fn blockHasTerminator(block: Block) bool {
    for (block.instructions) |instruction| {
        if (std.mem.eql(u8, instruction.kind, "return") or
            std.mem.eql(u8, instruction.kind, "break") or
            std.mem.eql(u8, instruction.kind, "continue") or
            std.mem.eql(u8, instruction.kind, "trap") or
            std.mem.eql(u8, instruction.kind, "asm"))
        {
            return true;
        }
    }
    return false;
}

fn blockLastSpan(block: Block) SourcePoint {
    if (block.instructions.len == 0) return .{ .line = 0, .column = 0 };
    const last = block.instructions[block.instructions.len - 1];
    return .{ .line = last.line, .column = last.column };
}

fn sourcePointSpan(point: SourcePoint) diagnostics.Span {
    return .{ .offset = 0, .len = 0, .line = point.line, .column = point.column };
}

fn binaryMayTrap(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

fn binaryTrapKind(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .div, .mod => "DivideByZero",
        .shl, .shr => "InvalidShift",
        .add, .sub, .mul => "IntegerOverflow",
        else => "Unknown",
    };
}

fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

fn isWrapPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}

fn exprText(expr: ast.Expr) []const u8 {
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
        .member => |node| node.name.text,
        .grouped => |inner| exprText(inner.*),
        else => @tagName(expr.kind),
    };
}

fn patternText(pattern: ast.Pattern) []const u8 {
    return switch (pattern.kind) {
        .wildcard => "_",
        .bind => |ident| ident.text,
        .tag => |ident| ident.text,
        .tag_bind => |node| node.tag.text,
        .literal => "literal",
    };
}

fn typeText(ty: ast.TypeExpr) []const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .enum_literal => |literal| literal.text,
        .member => |node| node.field.text,
        .nullable => "?",
        .qualified => |node| typeText(node.child.*),
        .pointer => "*",
        .raw_many_pointer => "[*]",
        .slice => "[]",
        .array => "array",
        .generic => |node| node.base.text,
    };
}

fn isTrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "trap"),
        .grouped => |inner| isTrapCall(inner.*),
        else => false,
    };
}

fn isUnwrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "unwrap"),
        .grouped => |inner| isUnwrapCall(inner.*),
        else => false,
    };
}

fn directCalleeName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| directCalleeName(inner.*),
        else => null,
    };
}

fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named => "unknown",
    };
}

fn hasNoLangTrap(attrs: []const ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .no_lang_trap) return true;
    }
    return false;
}

test "builds HIR CFG for branches and loops" {
    const source =
        \\fn branch(result: Result<u32, Error>, flag: bool) -> u32 {
        \\    if let ok(value) = result {
        \\        return value;
        \\    } else {
        \\        while flag {
        \\            return 0;
        \\        }
        \\    }
        \\    return 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "hir_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var hir = try build(std.testing.allocator, module);
    defer hir.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir.functions.len);
    try std.testing.expect(hir.functions[0].blocks.len >= 5);
}

test "HIR verifier reports fallthrough and no_lang_trap trap edges" {
    const source =
        \\fn missing_return(flag: bool) -> u32 {
        \\    if let value = null {
        \\        return 1;
        \\    }
        \\}
        \\
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn saturating_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_neg(a: wrap<u32>) -> wrap<u32> {
        \\    return -a;
        \\}
        \\
        \\fn trapping_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn calls_trapping(a: u32, b: u32) -> u32 {
        \\    return trapping_add(a, b);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "hir_verify.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);

    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=missing_return finding=fallthrough") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=checked_add finding=trap_edge detail=IntegerOverflow no_lang_trap=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=calls_trapping finding=trap_edge detail=CallMayTrap no_lang_trap=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=wrapping_add finding=trap_edge") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=saturating_add finding=trap_edge") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=wrapping_neg finding=trap_edge") == null);
}

test "HIR verifier reports structured diagnostics" {
    const source =
        \\fn missing_return(flag: bool) -> u32 {
        \\    if let value = null {
        \\        return 1;
        \\    }
        \\}
        \\
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "hir_verify_diagnostics.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    try std.testing.expect(reporter.has_errors);
    var found_missing_return = false;
    var found_no_lang_trap = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_MISSING") != null) found_missing_return = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang_trap = true;
    }
    try std.testing.expect(found_missing_return);
    try std.testing.expect(found_no_lang_trap);
}
