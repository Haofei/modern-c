const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir.zig");

pub fn appendLlvm(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var module_mir = try mir.build(allocator, module);
    defer module_mir.deinit();

    try out.appendSlice(allocator, "; MC LLVM IR backend v0\n");
    try out.appendSlice(allocator, "; semantic source: verified MC MIR\n\n");
    try emitTrapDecl(allocator, out);

    var ctx = LlvmEmitter{
        .allocator = allocator,
        .out = out,
        .mir_module = module_mir,
        .scratch = std.heap.ArenaAllocator.init(allocator),
        .need_uadd = std.StringHashMap(void).init(allocator),
        .need_usub = std.StringHashMap(void).init(allocator),
        .need_umul = std.StringHashMap(void).init(allocator),
        .need_sadd = std.StringHashMap(void).init(allocator),
        .need_ssub = std.StringHashMap(void).init(allocator),
        .need_smul = std.StringHashMap(void).init(allocator),
        .local_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_slots = std.StringHashMap(LocalSlot).init(allocator),
    };
    defer ctx.deinit();
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| if (fn_decl.body) |body| try ctx.emitFunction(fn_decl, body),
            .extern_fn => |fn_decl| try ctx.emitExternFunction(fn_decl),
            else => {},
        }
    }
    try ctx.emitIntrinsicDecls();
}

fn emitTrapDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "declare void @mc_trap_IntegerOverflow() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_DivideByZero() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_InvalidShift() noreturn\n\n");
}

const LlvmEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mir_module: mir.Module,
    scratch: std.heap.ArenaAllocator,
    temp_index: usize = 0,
    trap_index: usize = 0,
    need_uadd: std.StringHashMap(void) = undefined,
    need_usub: std.StringHashMap(void) = undefined,
    need_umul: std.StringHashMap(void) = undefined,
    need_sadd: std.StringHashMap(void) = undefined,
    need_ssub: std.StringHashMap(void) = undefined,
    need_smul: std.StringHashMap(void) = undefined,
    local_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_slots: std.StringHashMap(LocalSlot) = undefined,

    fn deinit(self: *LlvmEmitter) void {
        self.need_uadd.deinit();
        self.need_usub.deinit();
        self.need_umul.deinit();
        self.need_sadd.deinit();
        self.need_ssub.deinit();
        self.need_smul.deinit();
        self.local_types.deinit();
        self.local_slots.deinit();
        self.scratch.deinit();
    }

    fn emitFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl, body: ast.Block) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        try self.out.print(self.allocator, "define {s} @{s}(", .{ ret_llvm, fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} %{s}", .{ try self.llvmType(param.ty), param.name.text });
        }
        try self.out.appendSlice(self.allocator, ") {\nentry:\n");
        self.temp_index = 0;
        self.trap_index = 0;
        self.local_types.clearRetainingCapacity();
        self.local_slots.clearRetainingCapacity();
        for (fn_decl.params) |param| try self.local_types.put(param.name.text, param.ty);

        if (!try self.emitBlock(body, ret_ty)) return error.UnsupportedLlvmEmission;
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitExternFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        try self.out.print(self.allocator, "declare {s} @{s}(", .{ try self.llvmType(ret_ty), fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
        }
        try self.out.appendSlice(self.allocator, ")\n\n");
    }

    fn emitExpr(self: *LlvmEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr) anyerror![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| try self.emitIdent(ident),
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .bool_literal => |value| if (value) "1" else "0",
            .grouped => |inner| self.emitExpr(inner.*, expected_ty),
            .call => |call| try self.emitCall(call, expected_ty),
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expected_ty),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitIdent(self: *LlvmEmitter, ident: ast.Ident) ![]const u8 {
        if (self.local_slots.get(ident.text)) |slot| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(slot.ty), slot.ptr });
            return result;
        }
        return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
    }

    fn emitBlock(self: *LlvmEmitter, block: ast.Block, ret_ty: ast.TypeExpr) anyerror!bool {
        for (block.items) |stmt| {
            switch (stmt.kind) {
                .let_decl => |local| try self.emitLocalDecl(local),
                .var_decl => |local| try self.emitLocalDecl(local),
                .assignment => |node| try self.emitAssignment(node.target, node.value),
                .loop => |node| {
                    if (try self.emitWhile(node, ret_ty)) return true;
                },
                .@"return" => |maybe_expr| {
                    if (ret_ty.kind == .name and std.mem.eql(u8, ret_ty.kind.name.text, "void")) {
                        try self.out.appendSlice(self.allocator, "  ret void\n");
                    } else {
                        const expr = maybe_expr orelse return error.UnsupportedLlvmEmission;
                        const value = try self.emitExpr(expr, ret_ty);
                        try self.out.print(self.allocator, "  ret {s} {s}\n", .{ try self.llvmType(ret_ty), value });
                    }
                    return true;
                },
                .@"switch" => |node| return try self.emitBoolSwitch(node, ret_ty),
                else => return error.UnsupportedLlvmEmission,
            }
        }
        return false;
    }

    fn emitLocalDecl(self: *LlvmEmitter, local: ast.LocalDecl) !void {
        if (local.names.len != 1) return error.UnsupportedLlvmEmission;
        const ty = local.ty orelse return error.UnsupportedLlvmEmission;
        const init = local.init orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        const name = local.names[0].text;
        const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{name});
        const value = try self.emitExpr(init, ty);
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, llvm_ty });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
        try self.local_types.put(name, ty);
        try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr });
    }

    fn emitAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !void {
        const ident = assignmentIdent(target) orelse return error.UnsupportedLlvmEmission;
        const slot = self.local_slots.get(ident.text) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(slot.ty);
        const value = try self.emitExpr(value_expr, slot.ty);
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, slot.ptr });
    }

    fn emitWhile(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        if (loop.kind != .@"while") return error.UnsupportedLlvmEmission;
        const condition_expr = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const condition_ty = self.exprType(condition_expr) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(condition_ty, "bool")) return error.UnsupportedLlvmEmission;

        const cond_label = try self.nextLabel("while_cond");
        const body_label = try self.nextLabel("while_body");
        const end_label = try self.nextLabel("while_end");

        try self.out.print(self.allocator, "  br label %{s}\n{s}:\n", .{ cond_label, cond_label });
        const condition = try self.emitExpr(condition_expr, condition_ty);
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ condition, body_label, end_label, body_label });
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{cond_label});
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitBoolSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !bool {
        const subject_ty = self.exprType(node.subject) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(subject_ty, "bool")) return error.UnsupportedLlvmEmission;

        const true_arm = findBoolSwitchArm(node.arms, true);
        const false_arm = findBoolSwitchArm(node.arms, false) orelse findWildcardSwitchArm(node.arms);
        if (true_arm == null or false_arm == null) return error.UnsupportedLlvmEmission;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const true_label = try self.nextLabel("switch_true");
        const false_label = try self.nextLabel("switch_false");
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n", .{ subject, true_label, false_label });
        try self.out.print(self.allocator, "{s}:\n", .{true_label});
        if (!try self.emitSwitchBody(true_arm.?.body, ret_ty)) return error.UnsupportedLlvmEmission;
        try self.out.print(self.allocator, "{s}:\n", .{false_label});
        if (!try self.emitSwitchBody(false_arm.?.body, ret_ty)) return error.UnsupportedLlvmEmission;
        return true;
    }

    fn emitSwitchBody(self: *LlvmEmitter, body: ast.SwitchBody, ret_ty: ast.TypeExpr) !bool {
        return switch (body) {
            .block => |block| try self.emitBlock(block, ret_ty),
            .expr => |expr| blk: {
                const value = try self.emitExpr(expr, ret_ty);
                try self.out.print(self.allocator, "  ret {s} {s}\n", .{ try self.llvmType(ret_ty), value });
                break :blk true;
            },
        };
    }

    fn emitCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        const callee = switch (call.callee.kind) {
            .ident => |ident| ident.text,
            else => return error.UnsupportedLlvmEmission,
        };
        const ret_ty = try self.llvmType(expected_ty);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}(", .{ result, ret_ty, callee });
        for (call.args, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const arg_ty = expected_tyForCallArg(self.mir_module, callee, i) orelse expected_ty;
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg_ty), try self.emitExpr(arg, arg_ty) });
        }
        try self.out.appendSlice(self.allocator, ")\n");
        return result;
    }

    fn emitBinary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        if (binaryIsComparison(node.op)) return self.emitComparison(node, ty);
        const llvm_ty = try self.llvmType(ty);
        return switch (node.op) {
            .add, .sub, .mul => try self.emitCheckedArithmetic(node, ty, llvm_ty),
            .div => try self.emitPlainBinary("udiv", node, ty, llvm_ty),
            .mod => try self.emitPlainBinary("urem", node, ty, llvm_ty),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitUnary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        return switch (node.op) {
            .logical_not => blk: {
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ result, value });
                break :blk result;
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitComparison(self: *LlvmEmitter, node: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        if (!typeNameEql(expected_ty, "bool")) return error.UnsupportedLlvmEmission;
        const operand_ty = self.exprType(node.left.*) orelse self.exprType(node.right.*) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(operand_ty);
        const pred = comparisonPredicate(node.op, isSignedInteger(operand_ty)) orelse return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, operand_ty);
        const right = try self.emitExpr(node.right.*, operand_ty);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {s}\n", .{ result, pred, llvm_ty, left, right });
        return result;
    }

    fn emitCheckedArithmetic(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const bits = integerBits(ty) orelse return error.UnsupportedLlvmEmission;
        const signed = isSignedInteger(ty);
        const intrinsic = try self.overflowIntrinsic(node.op, signed, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s})\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow()\n  unreachable\n{s}:\n", .{ overflow, trap, cont, trap, cont });
        return value;
    }

    fn emitPlainBinary(self: *LlvmEmitter, op: []const u8, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ result, op, llvm_ty, left, right });
        return result;
    }

    fn overflowIntrinsic(self: *LlvmEmitter, op: ast.BinaryOp, signed: bool, bits: u16) ![]const u8 {
        const prefix = if (signed) "s" else "u";
        const name = switch (op) {
            .add => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}add.with.overflow.i{d}", .{ prefix, bits }),
            .sub => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}sub.with.overflow.i{d}", .{ prefix, bits }),
            .mul => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}mul.with.overflow.i{d}", .{ prefix, bits }),
            else => unreachable,
        };
        const set = switch (op) {
            .add => if (signed) &self.need_sadd else &self.need_uadd,
            .sub => if (signed) &self.need_ssub else &self.need_usub,
            .mul => if (signed) &self.need_smul else &self.need_umul,
            else => unreachable,
        };
        try set.put(name, {});
        return name;
    }

    fn emitIntrinsicDecls(self: *LlvmEmitter) !void {
        try self.emitIntrinsicSet(self.need_uadd);
        try self.emitIntrinsicSet(self.need_usub);
        try self.emitIntrinsicSet(self.need_umul);
        try self.emitIntrinsicSet(self.need_sadd);
        try self.emitIntrinsicSet(self.need_ssub);
        try self.emitIntrinsicSet(self.need_smul);
    }

    fn emitIntrinsicSet(self: *LlvmEmitter, set: std.StringHashMap(void)) !void {
        var it = set.keyIterator();
        while (it.next()) |name| {
            const bits = intrinsicBits(name.*) orelse continue;
            try self.out.print(self.allocator, "declare {{ i{d}, i1 }} @{s}(i{d}, i{d})\n", .{ bits, name.*, bits, bits });
        }
    }

    fn llvmType(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        return switch (ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "void"))
                "void"
            else if (std.mem.eql(u8, name.text, "bool"))
                "i1"
            else if (integerBits(ty)) |bits|
                try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{bits})
            else
                error.UnsupportedLlvmEmission,
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn nextTemp(self: *LlvmEmitter) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%t{d}", .{index});
    }

    fn nextLabel(self: *LlvmEmitter, prefix: []const u8) ![]const u8 {
        const index = self.trap_index;
        self.trap_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "{s}{d}", .{ prefix, index });
    }

    fn exprType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.local_types.get(ident.text),
            .bool_literal, .unary => simpleType(expr.span, "bool"),
            .int_literal => null,
            .grouped => |inner| self.exprType(inner.*),
            .binary => |node| if (binaryIsComparison(node.op)) simpleType(expr.span, "bool") else self.exprType(node.left.*),
            else => null,
        };
    }
};

const LocalSlot = struct {
    ty: ast.TypeExpr,
    ptr: []const u8,
};

fn assignmentIdent(target: ast.Expr) ?ast.Ident {
    return switch (target.kind) {
        .ident => |ident| ident,
        .grouped => |inner| assignmentIdent(inner.*),
        else => null,
    };
}

fn expected_tyForCallArg(module_mir: mir.Module, callee: []const u8, index: usize) ?ast.TypeExpr {
    _ = module_mir;
    _ = callee;
    _ = index;
    return null;
}

fn simpleType(span: ast.Span, name: []const u8) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .span = span, .text = name } } };
}

fn typeNameEql(ty: ast.TypeExpr, expected: []const u8) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, expected),
        else => false,
    };
}

fn findBoolSwitchArm(arms: []const ast.SwitchArm, value: bool) ?ast.SwitchArm {
    for (arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .literal => |expr| switch (expr.kind) {
                    .bool_literal => |literal| if (literal == value) return arm,
                    else => {},
                },
                else => {},
            }
        }
    }
    return null;
}

fn findWildcardSwitchArm(arms: []const ast.SwitchArm) ?ast.SwitchArm {
    for (arms) |arm| {
        for (arm.patterns) |pattern| {
            if (pattern.kind == .wildcard) return arm;
        }
    }
    return null;
}

fn binaryIsComparison(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn comparisonPredicate(op: ast.BinaryOp, signed: bool) ?[]const u8 {
    return switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => if (signed) "slt" else "ult",
        .le => if (signed) "sle" else "ule",
        .gt => if (signed) "sgt" else "ugt",
        .ge => if (signed) "sge" else "uge",
        else => null,
    };
}

fn normalizedIntLiteral(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

fn integerBits(ty: ast.TypeExpr) ?u16 {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return 8;
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return 16;
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return 32;
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return 64;
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return 64;
    return null;
}

fn isSignedInteger(ty: ast.TypeExpr) bool {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return false,
    };
    return std.mem.startsWith(u8, name, "i") or std.mem.eql(u8, name, "isize");
}

fn intrinsicBits(name: []const u8) ?u16 {
    if (std.mem.endsWith(u8, name, ".i8")) return 8;
    if (std.mem.endsWith(u8, name, ".i16")) return 16;
    if (std.mem.endsWith(u8, name, ".i32")) return 32;
    if (std.mem.endsWith(u8, name, ".i64")) return 64;
    return null;
}

test "LLVM backend emits checked integer add from MIR-gated source" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var reporter = @import("diagnostics.zig").Reporter.init(std.testing.allocator, "llvm_smoke.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = @import("parser.zig").Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvm(std.testing.allocator, module, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define i32 @add_one(i32 %value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@llvm.uadd.with.overflow.i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call void @mc_trap_IntegerOverflow()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " nsw ") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " nuw ") == null);
}
